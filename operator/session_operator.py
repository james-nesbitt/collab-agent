"""
kopf operator for omp.mirantis.io/v1alpha1/sessions.

Reconciles Session CRs into isolated per-session Kubernetes namespaces.
Each Session gets: Namespace, ServiceAccount, PVC, ExternalSecret (ESO),
ConfigMap (copied from omp-system master), NetworkPolicies, Pod.
GSM is accessed for secret metadata only (list, never access_secret_version).
Credentials arrive in pods via ESO → K8s Secret → envFrom.
"""

import base64
import logging
import os
import re
import secrets
import time

import kopf
import kubernetes
import kubernetes.client as k8s
import kubernetes.stream
from google.cloud import secretmanager

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration from environment
# ---------------------------------------------------------------------------
OMP_SESSION_IMAGE: str = os.environ.get(
    "OMP_SESSION_IMAGE",
    "ghcr.io/james-nesbitt/collab-agent/omp-session:latest",
)
OMP_GSM_PROJECT: str = os.environ.get("OMP_GSM_PROJECT", "")
OMP_RELAY: str = os.environ.get("OMP_RELAY", "")
OMP_GROUP_DOMAIN: str = os.environ.get("OMP_GROUP_DOMAIN", "mirantis.com")

GROUP = "omp.mirantis.io"
VERSION = "v1alpha1"
PLURAL = "sessions"

# ---------------------------------------------------------------------------
# Kubernetes client config (in-cluster; falls back to local kubeconfig)
# ---------------------------------------------------------------------------
try:
    kubernetes.config.load_incluster_config()
except kubernetes.config.ConfigException:
    kubernetes.config.load_kube_config()


# ---------------------------------------------------------------------------
# Transform helpers
# ---------------------------------------------------------------------------

def label(subtree: str) -> str:
    """Convert a subtree path to a k8s/GSM label-value-safe string (/ → -)."""
    return subtree.replace("/", "-")


def envname(secret_id: str, subtree: str) -> str:
    """
    Derive the env-var name from a GSM secret ID and its subtree.

    Strip the leading '{label(subtree)}-' prefix from the secret ID,
    uppercase, replace / and - with _, drop characters outside [A-Z0-9_].

    Examples:
        envname('services-github-token', 'services') → 'GITHUB_TOKEN'
        envname('services-anthropic-api-key', 'services') → 'ANTHROPIC_API_KEY'
    """
    prefix = f"{label(subtree)}-"
    remainder = secret_id[len(prefix):] if secret_id.startswith(prefix) else secret_id
    replaced = re.sub(r"[/\-]", "_", remainder.upper())
    return re.sub(r"[^A-Z0-9_]", "", replaced)


# ---------------------------------------------------------------------------
# GSM metadata listing (never accesses secret values)
# ---------------------------------------------------------------------------

def list_gsm_secrets(project: str, subtree: str) -> list[dict]:
    """
    List GSM secrets for a subtree using the label filter
    labels.omp_subtree={label(subtree)}.  Returns metadata only — never
    calls access_secret_version.  The operator SA has only secretmanager.viewer.
    """
    if not project:
        log.warning("OMP_GSM_PROJECT not set; skipping GSM lookup for subtree %s", subtree)
        return []
    client = secretmanager.SecretManagerServiceClient()
    results: list[dict] = []
    try:
        for secret in client.list_secrets(request={
            "parent": f"projects/{project}",
            "filter": f"labels.omp_subtree={label(subtree)}",
        }):
            # secret.name = projects/{project}/secrets/{id}
            results.append({"id": secret.name.split("/")[-1]})
    except Exception as exc:  # noqa: BLE001
        log.warning("GSM list_secrets failed for subtree %s: %s", subtree, exc)
    return results


# ---------------------------------------------------------------------------
# Kubernetes object builders
# ---------------------------------------------------------------------------

def _namespace(ns: str, session_name: str, team: str = "") -> k8s.V1Namespace:
    labels: dict = {"omp.mirantis.io/session": session_name}
    if team:
        labels["omp.mirantis.io/team"] = team
    return k8s.V1Namespace(
        metadata=k8s.V1ObjectMeta(name=ns, labels=labels)
    )


def _team_role(ns: str) -> k8s.V1Role:
    """Role granting a team exec/log access to pods in a session namespace (not secrets)."""
    return k8s.V1Role(
        metadata=k8s.V1ObjectMeta(name="omp-session-user", namespace=ns),
        rules=[
            k8s.V1PolicyRule(api_groups=[""], resources=["pods"], verbs=["get", "list", "watch"]),
            k8s.V1PolicyRule(api_groups=[""], resources=["pods/exec"], verbs=["create"]),
            k8s.V1PolicyRule(api_groups=[""], resources=["pods/log"], verbs=["get"]),
        ],
    )


def _team_rolebinding(ns: str, team: str) -> k8s.V1RoleBinding:
    """Bind the omp-session-user Role to the team's Google Group in a session namespace."""
    return k8s.V1RoleBinding(
        metadata=k8s.V1ObjectMeta(name="omp-session-user", namespace=ns),
        role_ref=k8s.V1RoleRef(
            api_group="rbac.authorization.k8s.io",
            kind="Role",
            name="omp-session-user",
        ),
        subjects=[
            k8s.RbacV1Subject(
                kind="Group",
                api_group="rbac.authorization.k8s.io",
                name=f"omp-team-{team}@{OMP_GROUP_DOMAIN}",
            )
        ],
    )

def _service_account(ns: str) -> k8s.V1ServiceAccount:
    # Not WI-annotated: session pods have no cloud identity.
    # The only path to GSM values is ESO → K8s Secret → envFrom.
    return k8s.V1ServiceAccount(
        metadata=k8s.V1ObjectMeta(name="omp-session", namespace=ns),
    )


def _pvc(ns: str) -> k8s.V1PersistentVolumeClaim:
    return k8s.V1PersistentVolumeClaim(
        metadata=k8s.V1ObjectMeta(name="omp-home", namespace=ns),
        spec=k8s.V1PersistentVolumeClaimSpec(
            access_modes=["ReadWriteOnce"],
            resources=k8s.V1VolumeResourceRequirements(
                requests={"storage": "50Gi"},
            ),
        ),
    )


def _external_secret(ns: str, subtrees: list, project: str) -> dict:
    """
    Build an ExternalSecret manifest that maps every matched GSM secret
    (across all subtrees) into a single K8s Secret named omp-creds.
    Uses ClusterSecretStore omp-gsm (WI via ESO SA).
    """
    data_entries = []
    for subtree in subtrees:
        for s in list_gsm_secrets(project, subtree):
            data_entries.append({
                "secretKey": envname(s["id"], subtree),
                "remoteRef": {"key": s["id"]},
            })
    return {
        "apiVersion": "external-secrets.io/v1",
        "kind": "ExternalSecret",
        "metadata": {"name": "omp-creds", "namespace": ns},
        "spec": {
            "secretStoreRef": {"kind": "ClusterSecretStore", "name": "omp-gsm"},
            "target": {"name": "omp-creds", "creationPolicy": "Owner"},
            "refreshInterval": "1h",
            "data": data_entries,
        },
    }


def _configmap_from_master(ns: str, config_ref: str = "omp-config") -> k8s.V1ConfigMap | None:
    """
    Copy a named ConfigMap from omp-system into the session namespace.

    config_ref names the ConfigMap in omp-system to copy (default: omp-config).
    Returns None (and logs a warning) if the named ConfigMap doesn't exist.
    """
    v1 = k8s.CoreV1Api()
    try:
        master = v1.read_namespaced_config_map(config_ref, "omp-system")
        return k8s.V1ConfigMap(
            metadata=k8s.V1ObjectMeta(name="omp-config", namespace=ns),
            data=master.data,
        )
    except k8s.ApiException as exc:
        if exc.status == 404:
            log.warning("%s not found in omp-system; session uses image defaults", config_ref)
            return None
        raise


def _network_policies(ns: str) -> list[dict]:
    """
    Three NetworkPolicy manifests for a session namespace:
    1. deny-all        — default-deny both Ingress and Egress
    2. allow-dns       — Egress to kube-system UDP/TCP 53
    3. allow-egress-https — Egress TCP 443 to internet, excluding RFC1918 +
                            GCE metadata server (169.254.169.254/32) to
                            prevent credential exfiltration via the metadata API
    """
    base = {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy"}
    return [
        {
            **base,
            "metadata": {"name": "deny-all", "namespace": ns},
            "spec": {
                "podSelector": {},
                "policyTypes": ["Ingress", "Egress"],
            },
        },
        {
            **base,
            "metadata": {"name": "allow-dns", "namespace": ns},
            "spec": {
                "podSelector": {},
                "policyTypes": ["Egress"],
                "egress": [{
                    "ports": [
                        {"port": 53, "protocol": "UDP"},
                        {"port": 53, "protocol": "TCP"},
                    ],
                    "to": [{"namespaceSelector": {
                        "matchLabels": {"kubernetes.io/metadata.name": "kube-system"},
                    }}],
                }],
            },
        },
        {
            **base,
            "metadata": {"name": "allow-egress-https", "namespace": ns},
            "spec": {
                "podSelector": {},
                "policyTypes": ["Egress"],
                "egress": [{
                    "ports": [{"port": 443, "protocol": "TCP"}],
                    "to": [{
                        "ipBlock": {
                            "cidr": "0.0.0.0/0",
                            "except": [
                                "10.0.0.0/8",
                                "172.16.0.0/12",
                                "192.168.0.0/16",
                                "169.254.169.254/32",
                            ],
                        }
                    }],
                }],
            },
        },
    ]


def _statefulset(ns: str, session_name: str, image: str, has_configmap: bool,
                 extra_env: dict | None = None, auth_broker: bool = False,
                 broker_token: str = "") -> dict:
    """Build a StatefulSet manifest (replicas=1) for a session pod."""
    env: list = [{"name": "OMP_SESSION_NAME", "value": session_name}]
    if OMP_RELAY:
        env.append({"name": "COLLAB_RELAY", "value": OMP_RELAY})
    for k, v in (extra_env or {}).items():
        env.append({"name": k, "value": v})
    if auth_broker and broker_token:
        env.append({"name": "OMP_AUTH_BROKER_URL", "value": "http://localhost:9999"})
        env.append({"name": "OMP_AUTH_BROKER_TOKEN", "value": broker_token})

    volume_mounts: list = [
        {"name": "omp-home", "mountPath": "/home/omp"},
        {"name": "docker-run", "mountPath": "/home/omp/.docker-run"},
    ]
    volumes: list = [
        {"name": "docker-run", "emptyDir": {}},
    ]

    if has_configmap:
        volume_mounts.append({"name": "omp-config", "mountPath": "/etc/omp", "readOnly": True})
        volumes.append({"name": "omp-config", "configMap": {"name": "omp-config"}})

    containers: list = [
        {
            "name": "omp",
            "image": image,
            "imagePullPolicy": "Always",
            "resources": {
                "requests": {"cpu": "500m", "memory": "1Gi"},
                "limits": {"memory": "12Gi"},
            },
            "env": env,
            "envFrom": [{"secretRef": {"name": "omp-creds", "optional": True}}],
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": 1000,
                "runAsGroup": 1000,
                "allowPrivilegeEscalation": True,
                "seccompProfile": {"type": "Unconfined"},
                "capabilities": {"drop": ["ALL"]},
            },
            "volumeMounts": volume_mounts,
        },
    ]
    if auth_broker and broker_token:
        containers.append({
            "name": "auth-broker",
            "image": image,
            "imagePullPolicy": "Always",
            "resources": {
                "requests": {"cpu": "50m", "memory": "128Mi"},
                "limits": {"memory": "512Mi"},
            },
            "command": ["omp", "auth-broker", "serve", "--bind", "localhost:9999"],
            "env": [{"name": "OMP_AUTH_BROKER_TOKEN", "value": broker_token}],
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": 1000,
                "runAsGroup": 1000,
                "allowPrivilegeEscalation": False,
                "seccompProfile": {"type": "Unconfined"},
                "capabilities": {"drop": ["ALL"]},
            },
            # Shares $HOME (PVC) with the main container so the broker's
            # SQLite credential DB is on the same persistent volume.
            "volumeMounts": [{"name": "omp-home", "mountPath": "/home/omp"}],
        })

    return {
        "apiVersion": "apps/v1",
        "kind": "StatefulSet",
        "metadata": {"name": "omp", "namespace": ns},
        "spec": {
            "serviceName": "omp",
            "replicas": 1,
            "selector": {"matchLabels": {"app": "omp", "session": session_name}},
            "template": {
                "metadata": {"labels": {"app": "omp", "session": session_name}},
                "spec": {
                    "serviceAccountName": "omp-session",
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 1000,
                        "runAsGroup": 1000,
                        "fsGroup": 1000,
                        "seccompProfile": {"type": "Unconfined"},
                    },
                    "containers": containers,
                    "volumes": volumes,
                },
            },
            "volumeClaimTemplates": [
                {
                    "metadata": {"name": "omp-home"},
                    "spec": {
                        "accessModes": ["ReadWriteOnce"],
                        "resources": {"requests": {"storage": "50Gi"}},
                    },
                }
            ],
        },
    }


def _headless_service(ns: str) -> dict:
    """Headless Service for the StatefulSet — enables stable DNS for omp-0."""
    return {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {"name": "omp", "namespace": ns},
        "spec": {
            "clusterIP": "None",
            "selector": {"app": "omp"},
        },
    }


# ---------------------------------------------------------------------------
# Low-level K8s apply helpers
# ---------------------------------------------------------------------------

def _create_or_skip(fn, *args) -> None:
    """Call fn(*args); silently ignore AlreadyExists (409)."""
    try:
        fn(*args)
    except k8s.ApiException as exc:
        if exc.status != 409:
            raise


def _apply_custom_object(
    group: str, version: str, namespace: str, plural: str, body: dict
) -> None:
    """Server-side apply a namespaced custom object (upsert, drift-safe)."""
    custom = k8s.CustomObjectsApi()
    custom.patch_namespaced_custom_object(
        group, version, namespace, plural, body["metadata"]["name"], body,
        field_manager="omp-operator",
        force=True,
        _content_type="application/apply-patch+yaml",
    )


def _apply_network_policy(ns: str, body: dict) -> None:
    """Server-side apply a NetworkPolicy (upsert, drift-safe)."""
    net = k8s.NetworkingV1Api()
    net.patch_namespaced_network_policy(
        body["metadata"]["name"], ns, body,
        field_manager="omp-operator",
        force=True,
        _content_type="application/apply-patch+yaml",
    )




def _apply_statefulset(ns: str, body: dict) -> None:
    """Create or replace the StatefulSet in ns."""
    apps = k8s.AppsV1Api()
    try:
        apps.create_namespaced_stateful_set(ns, body)
    except k8s.ApiException as exc:
        if exc.status != 409:
            raise
        apps.replace_namespaced_stateful_set("omp", ns, body)


def _apply_service(ns: str, body: dict) -> None:
    """Create the headless Service in ns; ignore AlreadyExists."""
    v1 = k8s.CoreV1Api()
    try:
        v1.create_namespaced_service(ns, body)
    except k8s.ApiException as exc:
        if exc.status != 409:
            raise


def _delete_statefulset(ns: str) -> None:
    """Delete StatefulSet 'omp' in ns; ignore 404. PVC survives (volumeClaimTemplate lifecycle)."""
    apps = k8s.AppsV1Api()
    try:
        apps.delete_namespaced_stateful_set("omp", ns)
    except k8s.ApiException as exc:
        if exc.status != 404:
            raise


def _ensure_broker_token_secret(v1: k8s.CoreV1Api, ns: str) -> str:
    """
    Return the auth-broker bearer token for the session namespace.

    Creates K8s Secret 'auth-broker-token' in ns on first call (random 32-byte
    hex token); returns the existing token on subsequent calls. The token is
    scoped to the pod lifetime: deleted when the namespace is GC'd.
    Never stored in GSM — it is ephemeral and session-scoped.
    """
    secret_name = "auth-broker-token"
    try:
        secret = v1.read_namespaced_secret(secret_name, ns)
        return base64.b64decode((secret.data or {}).get("token", "")).decode()
    except k8s.ApiException as exc:
        if exc.status != 404:
            raise
    # Generate and store a fresh token
    token = secrets.token_hex(32)
    secret = k8s.V1Secret(
        metadata=k8s.V1ObjectMeta(name=secret_name, namespace=ns),
        string_data={"token": token},
    )
    _create_or_skip(v1.create_namespaced_secret, ns, secret)
    return token


# ---------------------------------------------------------------------------
# Pod lifecycle helpers
# ---------------------------------------------------------------------------

def _delete_pod(ns: str) -> None:
    """Delete pod 'omp-0' in ns; ignore 404."""
    v1 = k8s.CoreV1Api()
    try:
        v1.delete_namespaced_pod("omp-0", ns)
    except k8s.ApiException as exc:
        if exc.status != 404:
            raise


def _wait_pod_gone(ns: str, timeout: int = 120) -> bool:
    """Poll until pod 'omp-0' in ns is fully deleted (404), or timeout. Returns True if gone."""
    v1 = k8s.CoreV1Api()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            v1.read_namespaced_pod("omp-0", ns)
        except k8s.ApiException as exc:
            if exc.status == 404:
                return True
        time.sleep(2)
    return False


def _pod_image(ns: str) -> str | None:
    """Return the image of pod 'omp-0' in ns, or None if the pod is absent."""
    v1 = k8s.CoreV1Api()
    try:
        pod = v1.read_namespaced_pod("omp-0", ns)
        return pod.spec.containers[0].image
    except k8s.ApiException as exc:
        if exc.status == 404:
            return None
        raise


# ---------------------------------------------------------------------------
# Pod readiness polling
# ---------------------------------------------------------------------------

def _wait_pod_ready(ns: str, timeout: int = 300) -> bool:
    """Poll until pod 'omp-0' in ns has condition Ready=True, or timeout expires."""
    v1 = k8s.CoreV1Api()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            pod = v1.read_namespaced_pod("omp-0", ns)
            conditions = (pod.status or k8s.V1PodStatus()).conditions or []
            if any(c.type == "Ready" and c.status == "True" for c in conditions):
                return True
        except k8s.ApiException:
            pass
        time.sleep(5)
    return False


# ---------------------------------------------------------------------------
# Join-link capture
# ---------------------------------------------------------------------------

def _tmux_capture_join_link(ns: str, view: bool = False) -> str | None:
    """
    Exec into the running omp pod and capture the collab join link.

    Sends /collab (or /collab view) to the tmux session, waits for omp to
    process it (~8 s), then captures the pane and greps for the
    'omp join "..."' token.

    Returns the raw 'omp join "..."' string, or None if not found.
    """
    slash_cmd = "/collab view" if view else "/collab"
    # One-liner: send command, wait, capture pane, grep for join token
    shell = (
        f"tmux send-keys -t omp '{slash_cmd}' && "
        "sleep 1 && "
        "tmux send-keys -t omp Enter && "
        "sleep 8 && "
        "tmux capture-pane -p -J -S -25 -t omp | "
        "grep -oE 'omp join \"[^\"]+\"' | tail -1"
    )
    v1 = k8s.CoreV1Api()
    try:
        output: str = kubernetes.stream.stream(
            v1.connect_get_namespaced_pod_exec,
            "omp-0",
            ns,
            command=["sh", "-c", shell],
            stdout=True,
            stderr=True,
            stdin=False,
            tty=False,
        )
        output = (output or "").strip()
        if output.startswith("omp join"):
            return output
    except Exception as exc:  # noqa: BLE001
        log.warning("capture_join_link failed in namespace %s: %s", ns, exc)
    return None


def _read_join_link_file(ns: str, view: bool = False) -> str | None:
    """
    Read the collab link from ~/.omp/collab-link.json in the session pod.
    omp writes this file on hosting-start; the operator reads it once the
    pod is Ready. More reliable than tmux pane scraping (Option C, plan 2026-07-06).
    Retries up to max_attempts times with 5s sleep between attempts.
    Falls back to tmux capture if the file is absent after all attempts.
    """
    v1 = k8s.CoreV1Api()
    field = "viewLink" if view else "joinLink"
    max_attempts = 6  # 6 × 5s = 30s max wait before falling back
    for attempt in range(max_attempts):
        try:
            resp: str = kubernetes.stream.stream(
                v1.connect_get_namespaced_pod_exec,
                "omp-0",
                ns,
                command=["cat", "/home/omp/.omp/collab-link.json"],
                stderr=True, stdin=False, stdout=True, tty=False,
            )
            import json as _json  # noqa: PLC0415
            data = _json.loads(resp)
            link = data.get(field) or data.get("joinLink")
            if link:
                return link
        except Exception:  # noqa: BLE001
            pass
        if attempt < max_attempts - 1:
            time.sleep(5)

    # Fallback: tmux pane capture (kept for compatibility if omp version lacks file output)
    log.warning(
        "collab-link.json not found in omp-0/%s after %d attempts; falling back to tmux scrape",
        ns, max_attempts,
    )
    return _tmux_capture_join_link(ns, view)


# ---------------------------------------------------------------------------
# Status patching helper (direct API call for interim updates)
# ---------------------------------------------------------------------------

def _patch_cr_status(cr_namespace: str, cr_name: str, **fields) -> None:
    """Write status fields directly to the Session CR (not buffered via kopf patch)."""
    custom = k8s.CustomObjectsApi()
    try:
        custom.patch_namespaced_custom_object_status(
            GROUP, VERSION, cr_namespace, PLURAL, cr_name,
            {"status": fields},
        )
    except k8s.ApiException as exc:
        log.warning("Status patch failed for %s/%s: %s", cr_namespace, cr_name, exc)


# ---------------------------------------------------------------------------
# kopf operator settings
# ---------------------------------------------------------------------------

@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_) -> None:
    settings.persistence.finalizer = f"{GROUP}/finalizer"
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


# ---------------------------------------------------------------------------
# Reconcile: create + resume
# ---------------------------------------------------------------------------

@kopf.on.create(GROUP, VERSION, PLURAL)
@kopf.on.resume(GROUP, VERSION, PLURAL)
@kopf.on.update(GROUP, VERSION, PLURAL)
def reconcile(spec, name, namespace, status, annotations, patch, logger, **_) -> None:
    """
    Reconcile a Session CR:

    1. Create Namespace omp-session-{name}
    2. Create ServiceAccount omp-session (no WI annotation)
    3. Create PVC omp-home (50Gi RWO)
    4. Create ExternalSecret omp-creds (GSM subtrees → K8s Secret via ESO)
    5. Copy ConfigMap omp-config from omp-system
    6. Apply three NetworkPolicies (deny-all / allow-dns / allow-egress-https)
    7. Create Pod omp
    8. Wait for Pod Ready
    9. Capture collab join link via pod exec, set status.phase=Hosting
    """
    subtrees: list = list(spec.get("subtrees", []))
    view: bool = bool(spec.get("view", False))
    config_ref: str = spec.get("configRef", "omp-config")
    extra_env: dict = dict(spec.get("env", {}))
    auth_broker: bool = bool(spec.get("authBroker", False))
    team: str = spec.get("team", "")
    ns: str = f"omp-session-{team}-{name}" if team else f"omp-session-{name}"

    # Guard: team sessions must live in their own CR namespace (prevents spoofing)
    if team and namespace != f"omp-team-{team}":
        _patch_cr_status(namespace, name, phase="Failed",
                         message=f"spec.team '{team}' requires CR namespace omp-team-{team}")
        return

    _patch_cr_status(namespace, name, phase="Provisioning")

    v1 = k8s.CoreV1Api()

    # 1. Namespace
    _create_or_skip(v1.create_namespace, _namespace(ns, name, team))
    logger.info("Namespace %s ready", ns)

    # 1b. Team RBAC: grant team group exec/log in session namespace (not secrets)
    if team:
        rbac = k8s.RbacAuthorizationV1Api()
        _create_or_skip(rbac.create_namespaced_role, ns, _team_role(ns))
        _create_or_skip(rbac.create_namespaced_role_binding, ns, _team_rolebinding(ns, team))
        logger.info("Bound team %s to namespace %s (exec/log)", team, ns)

    # 2. ServiceAccount
    _create_or_skip(v1.create_namespaced_service_account, ns, _service_account(ns))


    cm = _configmap_from_master(ns, config_ref)
    has_cm = cm is not None
    if cm:
        # SSA patch: upserts the ConfigMap on create and drift; field_manager owns config data.
        v1.patch_namespaced_config_map(
            "omp-config", ns, cm,
            field_manager="omp-operator",
            force=True,
            _content_type="application/apply-patch+yaml",
        )

    # 6. NetworkPolicies
    for np in _network_policies(ns):
        _apply_network_policy(ns, np)

    # 7. State-aware pod convergence
    desired_state = spec.get("state", "running")
    desired_image = spec.get("image") or OMP_SESSION_IMAGE
    restart_nonce = (annotations or {}).get("omp.mirantis.io/restartedAt")
    applied_nonce = (status or {}).get("restartedAt")

    if desired_state == "stopped":
        apps = k8s.AppsV1Api()
        try:
            apps.patch_namespaced_stateful_set("omp", ns, {"spec": {"replicas": 0}})
        except k8s.ApiException as exc:
            if exc.status != 404:
                raise
        patch.status["phase"] = "Stopped"
        patch.status["namespace"] = ns
        patch.status["podName"] = ""
        patch.status["joinLink"] = ""
        patch.status["viewLink"] = ""
        logger.info("Session %s stopped (StatefulSet scaled to 0; namespace + PVC retained)", name)
        return

    current_image = _pod_image(ns)
    must_recreate = current_image is not None and (
        current_image != desired_image or restart_nonce != applied_nonce
    )
    created = False
    if current_image is None or must_recreate:
        # 2c. Auth-broker token secret (idempotent; generates only on first call)
        broker_token = ""
        if auth_broker:
            broker_token = _ensure_broker_token_secret(v1, ns)
            patch.status["authBrokerUrl"] = "http://localhost:9999"
            logger.info("Auth-broker enabled for session %s (token stored in auth-broker-token secret)", name)
        _apply_service(ns, _headless_service(ns))
        _apply_statefulset(ns, _statefulset(ns, name, desired_image, has_cm, extra_env, auth_broker=auth_broker, broker_token=broker_token))
        created = True
        patch.status["restartedAt"] = restart_nonce or ""

    patch.status["phase"] = "Running"
    patch.status["namespace"] = ns
    patch.status["podName"] = "omp-0"
    logger.info("Pod converged in %s (image=%s, recreated=%s)", ns, desired_image, created)

    # 8. Wait for pod Ready
    if not _wait_pod_ready(ns, timeout=300):
        patch.status["message"] = "Pod not Ready within 300s"
        logger.warning("Pod omp in %s not Ready after 300s", ns)
        return

    # 9. Capture join link only when pod was (re)created or link is missing
    if not created and (status or {}).get("joinLink"):
        # Pod is current and link already captured — nothing to do
        return

    link = _read_join_link_file(ns, view=view)
    if not link:
        logger.info("Join link not found on first attempt; retrying in 15s")
        time.sleep(15)
        link = _read_join_link_file(ns, view=view)

    if link:
        patch.status["joinLink"] = link
        patch.status["phase"] = "Hosting"
        patch.status["namespace"] = ns
        patch.status["podName"] = "omp-0"
        logger.info("Session %s hosting: %s", name, link)
        # Capture read-only view link too (when session is not already view-only)
        if not view:
            view_link = _read_join_link_file(ns, view=True)
            if view_link:
                patch.status["viewLink"] = view_link
    else:
        patch.status["phase"] = "Running"
        patch.status["namespace"] = ns
        patch.status["podName"] = "omp-0"
        patch.status["message"] = "Join link unavailable; session running without collab link"
        logger.warning("Could not capture join link for session %s", name)


# ---------------------------------------------------------------------------
# Delete handler
# ---------------------------------------------------------------------------
@kopf.on.delete(GROUP, VERSION, PLURAL)
def delete(name, spec, status, patch, logger, **_) -> None:
    """
    Delete the session namespace.  All session resources (PVC, Secret,
    ExternalSecret, NetworkPolicies, Pod, ConfigMap, SA) cascade automatically
    because they live inside that namespace.
    """
    team: str = (spec or {}).get("team", "")
    ns: str = ((status or {}).get("namespace")
               or (f"omp-session-{team}-{name}" if team else f"omp-session-{name}"))
    patch.status["phase"] = "Terminating"
    v1 = k8s.CoreV1Api()
    try:
        v1.delete_namespace(ns)
        logger.info("Deleted namespace %s (resources cascaded)", ns)
    except k8s.ApiException as exc:
        if exc.status != 404:
            raise
        logger.info("Namespace %s already absent", ns)


# ---------------------------------------------------------------------------
# Recapture handler — re-run link capture when annotation is bumped
# ---------------------------------------------------------------------------

@kopf.on.field(GROUP, VERSION, PLURAL, field="metadata.annotations")
def on_recapture(spec, name, namespace, old, new, logger, **_) -> None:
    """
    Re-capture the collab join/view link when the recapture annotation changes.
    Used after manual omp auth login to surface the link without restarting the pod.
    """
    RECAPTURE = "omp.mirantis.io/recapture"
    old_val = (old or {}).get(RECAPTURE)
    new_val = (new or {}).get(RECAPTURE)
    if new_val is None or new_val == old_val:
        return  # annotation absent or unchanged — not a recapture request

    team: str = spec.get("team", "")
    ns = f"omp-session-{team}-{name}" if team else f"omp-session-{name}"
    view: bool = bool(spec.get("view", False))
    logger.info("Recapture requested for session %s", name)

    link = _read_join_link_file(ns, view=view)
    if not link:
        logger.info("Link not found on first attempt; retrying in 15s")
        time.sleep(15)
        link = _read_join_link_file(ns, view=view)

    if link:
        _patch_cr_status(namespace, name, phase="Hosting", joinLink=link,
                         namespace=ns, podName="omp-0")
        logger.info("Recaptured join link for session %s", name)
        if not view:
            view_link = _read_join_link_file(ns, view=True)
            if view_link:
                _patch_cr_status(namespace, name, viewLink=view_link)
    else:
        logger.warning("Failed to recapture join link for session %s", name)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    kopf.run(clusterwide=True)
