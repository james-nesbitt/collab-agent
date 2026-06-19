"""
kopf operator for omp.mirantis.io/v1alpha1/sessions.

Reconciles Session CRs into isolated per-session Kubernetes namespaces.
Each Session gets: Namespace, ServiceAccount, PVC, ExternalSecret (ESO),
ConfigMap (copied from omp-system master), NetworkPolicies, Pod.
GSM is accessed for secret metadata only (list, never access_secret_version).
Credentials arrive in pods via ESO → K8s Secret → envFrom.
"""

import logging
import os
import re
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

def _namespace(ns: str, session_name: str) -> k8s.V1Namespace:
    return k8s.V1Namespace(
        metadata=k8s.V1ObjectMeta(
            name=ns,
            labels={"omp.mirantis.io/session": session_name},
        )
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


def _configmap_from_master(ns: str) -> k8s.V1ConfigMap | None:
    """
    Copy the master omp-config ConfigMap from omp-system into the session
    namespace so the pod picks up the operator-managed omp config.
    Returns None (and logs a warning) if the master doesn't exist yet.
    """
    v1 = k8s.CoreV1Api()
    try:
        master = v1.read_namespaced_config_map("omp-config", "omp-system")
        return k8s.V1ConfigMap(
            metadata=k8s.V1ObjectMeta(name="omp-config", namespace=ns),
            data=master.data,
        )
    except k8s.ApiException as exc:
        if exc.status == 404:
            log.warning("omp-config not found in omp-system; session uses image defaults")
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


def _pod(ns: str, session_name: str, image: str, has_configmap: bool, has_pull_secret: bool = False, extra_env: dict | None = None) -> k8s.V1Pod:
    """
    Build the session pod manifest.

    securityContext mirrors the documented rootless-docker-in-pod recipe:
    - runAsNonRoot + uid/gid 1000 (the 'omp' user in the image)
    - allowPrivilegeEscalation=true so setuid newuidmap/newgidmap work
    - seccompProfile Unconfined (rootless engines need user-namespace syscalls)
    - capabilities.drop ALL, no added caps, not privileged
    - fsGroup 1000 so the PVC is owned by the omp user on mount

    An emptyDir at /home/omp/.docker-run keeps the rootless-dockerd runtime
    directory off the PVC (prevents stale socket paths across node reschedules).
    """
    env = [k8s.V1EnvVar(name="OMP_SESSION_NAME", value=session_name)]
    if OMP_RELAY:
        env.append(k8s.V1EnvVar(name="COLLAB_RELAY", value=OMP_RELAY))
    for k, v in (extra_env or {}).items():
        env.append(k8s.V1EnvVar(name=k, value=v))

    volume_mounts = [
        k8s.V1VolumeMount(name="omp-home", mount_path="/home/omp"),
        k8s.V1VolumeMount(name="docker-run", mount_path="/home/omp/.docker-run"),
    ]
    volumes: list[k8s.V1Volume] = [
        k8s.V1Volume(
            name="omp-home",
            persistent_volume_claim=k8s.V1PersistentVolumeClaimVolumeSource(
                claim_name="omp-home"
            ),
        ),
        k8s.V1Volume(name="docker-run", empty_dir=k8s.V1EmptyDirVolumeSource()),
    ]

    if has_configmap:
        volume_mounts.append(
            k8s.V1VolumeMount(name="omp-config", mount_path="/etc/omp", read_only=True)
        )
        volumes.append(
            k8s.V1Volume(
                name="omp-config",
                config_map=k8s.V1ConfigMapVolumeSource(name="omp-config"),
            )
        )

    image_pull_secrets = (
        [k8s.V1LocalObjectReference(name="ghcr-pull-secret")] if has_pull_secret else None
    )
    return k8s.V1Pod(
        metadata=k8s.V1ObjectMeta(name="omp", namespace=ns),
        spec=k8s.V1PodSpec(
            service_account_name="omp-session",
            restart_policy="Always",
            image_pull_secrets=image_pull_secrets,
            security_context=k8s.V1PodSecurityContext(
                run_as_non_root=True,
                run_as_user=1000,
                run_as_group=1000,
                fs_group=1000,
                seccomp_profile=k8s.V1SeccompProfile(type="Unconfined"),
            ),
            containers=[
                k8s.V1Container(
                    name="omp",
                    image=image,
                    image_pull_policy="Always",
                    env=env,
                    env_from=[
                        k8s.V1EnvFromSource(
                            secret_ref=k8s.V1SecretEnvSource(
                                name="omp-creds", optional=True
                            )
                        ),
                        k8s.V1EnvFromSource(
                            secret_ref=k8s.V1SecretEnvSource(
                                name="omp-bootstrap-env", optional=True
                            )
                        ),
                    ],
                    security_context=k8s.V1SecurityContext(
                        run_as_non_root=True,
                        run_as_user=1000,
                        run_as_group=1000,
                        allow_privilege_escalation=True,
                        seccomp_profile=k8s.V1SeccompProfile(type="Unconfined"),
                        capabilities=k8s.V1Capabilities(drop=["ALL"]),
                    ),
                    volume_mounts=volume_mounts,
                )
            ],
            volumes=volumes,
        ),
    )


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
    """Create a namespaced custom object; ignore AlreadyExists."""
    custom = k8s.CustomObjectsApi()
    try:
        custom.create_namespaced_custom_object(group, version, namespace, plural, body)
    except k8s.ApiException as exc:
        if exc.status != 409:
            raise


def _apply_network_policy(ns: str, body: dict) -> None:
    net = k8s.NetworkingV1Api()
    try:
        net.create_namespaced_network_policy(ns, body)
    except k8s.ApiException as exc:
        if exc.status != 409:
            raise


def _copy_secret(v1: k8s.CoreV1Api, ns: str, secret_name: str, src_ns: str = "omp-system") -> bool:
    """Copy a Secret from src_ns into ns. Returns True if copied/already present, False if absent."""
    try:
        src = v1.read_namespaced_secret(secret_name, src_ns)
    except k8s.ApiException as exc:
        if exc.status == 404:
            return False
        raise
    dst = k8s.V1Secret(
        metadata=k8s.V1ObjectMeta(name=secret_name, namespace=ns),
        type=src.type,
        data=src.data,
    )
    _create_or_skip(v1.create_namespaced_secret, ns, dst)
    return True


# ---------------------------------------------------------------------------
# Pod readiness polling
# ---------------------------------------------------------------------------

def _wait_pod_ready(ns: str, timeout: int = 300) -> bool:
    """Poll until pod 'omp' in ns has condition Ready=True, or timeout expires."""
    v1 = k8s.CoreV1Api()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            pod = v1.read_namespaced_pod("omp", ns)
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

def _capture_join_link(ns: str, view: bool = False) -> str | None:
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
            "omp",
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


# ---------------------------------------------------------------------------
# Reconcile: create + resume
# ---------------------------------------------------------------------------

@kopf.on.create(GROUP, VERSION, PLURAL)
@kopf.on.resume(GROUP, VERSION, PLURAL)
def reconcile(spec, name, namespace, patch, logger, **_) -> None:
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
    subtrees: list = list(spec.get("subtrees", ["services"]))
    view: bool = bool(spec.get("view", False))
    image: str = spec.get("image") or OMP_SESSION_IMAGE
    extra_env: dict = dict(spec.get("env", {}))
    ns: str = f"omp-session-{name}"

    _patch_cr_status(namespace, name, phase="Provisioning")

    v1 = k8s.CoreV1Api()

    # 1. Namespace
    _create_or_skip(v1.create_namespace, _namespace(ns, name))
    logger.info("Namespace %s ready", ns)

    # 2. ServiceAccount
    _create_or_skip(v1.create_namespaced_service_account, ns, _service_account(ns))

    # 2b. Copy secrets from omp-system that are present (gracefully absent if not yet created)
    has_pull_secret = _copy_secret(v1, ns, "ghcr-pull-secret")
    if has_pull_secret:
        logger.info("Copied ghcr-pull-secret into %s", ns)
    if _copy_secret(v1, ns, "omp-bootstrap-env"):
        logger.info("Copied omp-bootstrap-env into %s", ns)

    # 3. PVC
    _create_or_skip(v1.create_namespaced_persistent_volume_claim, ns, _pvc(ns))

    # 4. ExternalSecret — skip if no data entries (ESO rejects empty data/dataFrom)
    es = _external_secret(ns, subtrees, OMP_GSM_PROJECT)
    if not es["spec"]["data"]:
        logger.warning("No GSM secrets matched subtrees %s for session %s; skipping ExternalSecret", subtrees, name)
        patch.status["message"] = "no credentials matched subtrees"
    else:
        _apply_custom_object("external-secrets.io", "v1", ns, "externalsecrets", es)

    # 5. ConfigMap
    cm = _configmap_from_master(ns)
    has_cm = cm is not None
    if cm:
        _create_or_skip(v1.create_namespaced_config_map, ns, cm)

    # 6. NetworkPolicies
    for np in _network_policies(ns):
        _apply_network_policy(ns, np)

    # 7. Pod
    _create_or_skip(v1.create_namespaced_pod, ns, _pod(ns, name, image, has_cm, has_pull_secret, extra_env))

    _patch_cr_status(namespace, name, phase="Running", namespace=ns, podName="omp")
    logger.info("Pod created in %s; waiting for Ready", ns)

    # 8. Wait for pod Ready
    if not _wait_pod_ready(ns, timeout=300):
        patch.status["phase"] = "Running"
        patch.status["namespace"] = ns
        patch.status["podName"] = "omp"
        patch.status["message"] = "Pod not Ready within 300s"
        logger.warning("Pod omp in %s not Ready after 300s", ns)
        return

    # 9. Capture join link; retry once with longer back-off
    link = _capture_join_link(ns, view=view)
    if not link:
        logger.info("Join link not found on first attempt; retrying in 15s")
        time.sleep(15)
        link = _capture_join_link(ns, view=view)

    if link:
        patch.status["joinLink"] = link
        patch.status["phase"] = "Hosting"
        patch.status["namespace"] = ns
        patch.status["podName"] = "omp"
        logger.info("Session %s hosting: %s", name, link)
        # Capture read-only view link too (when session is not already view-only)
        if not view:
            view_link = _capture_join_link(ns, view=True)
            if view_link:
                patch.status["viewLink"] = view_link
    else:
        patch.status["phase"] = "Running"
        patch.status["namespace"] = ns
        patch.status["podName"] = "omp"
        patch.status["message"] = "Join link unavailable; session running without collab link"
        logger.warning("Could not capture join link for session %s", name)


# ---------------------------------------------------------------------------
# Delete handler
# ---------------------------------------------------------------------------

@kopf.on.delete(GROUP, VERSION, PLURAL)
def delete(name, patch, logger, **_) -> None:
    """
    Delete the session namespace.  All session resources (PVC, Secret,
    ExternalSecret, NetworkPolicies, Pod, ConfigMap, SA) cascade automatically
    because they live inside that namespace.
    """
    ns = f"omp-session-{name}"
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
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    kopf.run(clusterwide=True)
