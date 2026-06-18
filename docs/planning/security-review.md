# Security Review (GKE architecture)

**Scope:** GKE-based remote-agent-machine — all shell scripts, Python operator, Dockerfiles,
Kubernetes manifests, and platform agent-guidance assets.  
**Method:** Full static read of every source file; line-level finding citations throughout.  
**Date:** 2026-06-18  
**Reviewer:** Application security engineer (shell / Kubernetes / supply-chain)  
**Prior review:** The earlier VM/SSH/pass/GPG-based review is superseded in its entirety;
findings F1 (session-name injection) and F2 (sed/valid\_token) from that review were fixed
before this architecture was written. No GPG vault remains.

─

## Summary

| ID  | Severity | Title                                              | Status    |
|-----|----------|----------------------------------------------------|-----------|
| F01 | High     | curl\|sh mise install — unverified code execution  | Open      |
| F02 | High     | Operator ClusterRole grants secrets CRUD to all ns | Open      |
| F03 | High     | ESO SA has project-wide secretAccessor (all GSM)   | Open      |
| F04 | Medium   | Helm ESO chart installed without `--version` pin   | Open      |
| F05 | Medium   | OCI image tags default to `latest` (no digest)     | Open      |
| F06 | Medium   | Collab join link stored in plain-text CR status    | Open      |
| F07 | Medium   | RFC 6598 (100.64.0.0/10) missing from egress except | Open     |
| F08 | Medium   | k8s manifests contain raw `${VAR}` — unsafe direct apply | Open |
| F09 | Low      | Session pod auto-mounts an unused SA token         | Open      |
| F10 | Low      | `resource_exists` uses unquoted `${subcmd}`        | Open      |
| F11 | Low      | Operator Deployment lacks container securityContext | Open     |
| F12 | Low      | Session namespaces created without PSA labels      | Open      |
| F13 | Low      | `set -x` / `bash -x` risk absent from agent rules  | Open     |
| F14 | Info     | Base images use mutable tags (no digest pin)       | Open      |
| F15 | Info     | GCP project ID hard-coded as default               | Open      |
| F16 | Info     | ExternalSecret API version hard-coded to v1        | Open      |

─

## Findings

### F01 — High — curl|sh mise install: unverified code execution at build time

**File:** `Dockerfile:35`

```dockerfile
RUN curl -fsSL https://mise.run | sh && \
```

The mise installer is fetched over HTTPS and immediately piped to `sh` with no checksum
verification and no pinned version. A compromise of mise.run's DNS, CDN edge, or TLS
certificate authority allows an attacker to substitute an arbitrary shell script that
executes as user `omp` during image build. This is the highest-severity supply-chain
vector in the codebase because:

1. It runs during `docker build`, not at container startup — it cannot be audited at
   deploy time.
2. The compromised code runs as user `omp` inside the build layer that also installs
   `bun@latest` (line 38) and `@oh-my-pi/pi-coding-agent` without a version pin (line 39),
   meaning a single poisoned fetch contaminates the entire toolchain layer.
3. The same layer adds `$HOME/.local/bin` to `PATH` in `.profile`, so any binary dropped
   by the installer persists into the final image.

`bun@latest` on line 38 is a second unpinned install in the same build step. The npm
package `@oh-my-pi/pi-coding-agent` on line 39 installs without a semver pin or
lockfile verification, which is a third supply-chain dependency.

**Impact:** Full arbitrary code execution in every session container image built from
this Dockerfile. An attacker who owns the `latest` of any of these three packages can
inject a backdoor that survives in the OCI layer.

**Fix:**
- Pin mise to a specific release and verify the SHA-256 of the binary directly:
  ```dockerfile
  ARG MISE_VERSION=2025.5.16
  ARG MISE_SHA256=<known-hash>
  RUN curl -fsSL "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-x64" \
          -o /tmp/mise && \
      echo "${MISE_SHA256}  /tmp/mise" | sha256sum -c && \
      install -m755 /tmp/mise /usr/local/bin/mise
  ```
- Pin `bun` to an exact version: `mise use -g bun@1.x.y`.
- Pin the npm package: `bun install -g @oh-my-pi/pi-coding-agent@<version>`.

─

### F02 — High — Operator ClusterRole grants `secrets` CRUD to every namespace

**File:** `k8s/operator-rbac.yaml:31`

```yaml
- apiGroups: [""]
  resources: ["pods", "pods/exec", "persistentvolumeclaims", "secrets", "configmaps", "serviceaccounts"]
  verbs: ["create", "get", "list", "watch", "delete", "update", "patch"]
```

This rule is part of a **ClusterRole** bound by a **ClusterRoleBinding** (lines 42–53),
so it applies to every namespace in the cluster.

The operator (`session_operator.py`) creates Namespaces, ServiceAccounts, PVCs,
ExternalSecrets, ConfigMaps, NetworkPolicies, and Pods. It never creates a K8s Secret
directly — that is ESO's job. There is no call to any Secrets API in
`session_operator.py`. The `secrets` verbs are entirely superfluous in the current
implementation.

Consequences of the over-provisioned ClusterRole:

1. **Cross-session credential theft.** `get` + `list` on `secrets` cluster-wide means
   the operator can read the `omp-creds` K8s Secret from every session namespace,
   effectively giving the operator process access to all injected credentials across all
   running sessions simultaneously.

2. **kube-system and infrastructure secrets.** The same permission extends to
   `kube-system`, `external-secrets`, and any other namespace. Bootstrap tokens,
   the ESO SA token projection, and internal service secrets are all readable.

3. **`pods/exec` cluster-wide.** The operator can exec into any pod in any namespace —
   not only `omp-session-*` pods. Combined with the `secrets` read, a compromised
   operator pod becomes a full-cluster credential harvester.

4. **Blast radius amplification via `latest` image tag (F05).** If a malicious image
   is pushed as `omp-operator:latest`, it inherits these permissions immediately on
   the next deployment rollout.

**Impact:** Compromise of the operator pod (via image substitution, container escape,
or a logic bug in `session_operator.py`) immediately yields all session credentials
cluster-wide. This violates the per-session credential isolation the architecture is
designed to provide.

**Fix:**

Remove `secrets` from the ClusterRole entirely. Add a separate namespace-scoped Role
in each `omp-session-*` namespace if the operator ever needs to inspect the `omp-creds`
Secret. For the current codebase no Secret verb is needed at all.

```yaml
# k8s/operator-rbac.yaml — replace the combined rule with two separate ones
- apiGroups: [""]
  resources: ["pods", "pods/exec", "persistentvolumeclaims", "configmaps", "serviceaccounts"]
  verbs: ["create", "get", "list", "watch", "delete", "update", "patch"]
# secrets rule removed entirely; ESO manages omp-creds, operator never touches it
```

Scope `pods`, `pods/exec`, `persistentvolumeclaims`, `configmaps`, and
`serviceaccounts` further by replacing the ClusterRole with a Role dynamically created
in each `omp-session-*` namespace at provisioning time, retaining the ClusterRole only
for `namespaces` management and Session CR status.

─

### F03 — High — ESO GCP SA holds project-wide `secretAccessor`

**File:** `administrator.sh:212–215`

```bash
gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
    --member="serviceAccount:${SA_ESO}" \
    --role="roles/secretmanager.secretAccessor" \
    --quiet
```

The `roles/secretmanager.secretAccessor` IAM role is bound at the **project level**,
not on specific secrets. The ESO SA (`omp-eso`) can therefore call
`secretmanager.versions.access` on **any** secret in the project — including secrets
that are not omp-managed, have no `omp_vault=true` label, and were created by
unrelated services or teams. The label-based filtering in `vault-ls`
(`administrator.sh:512–515`) and the operator's `list_secrets` filter
(`session_operator.py:89–92`) are applied after the fact at the application layer;
they do not restrict GSM IAM.

**Impact:** Exfiltration of all project secrets if the Workload Identity token for
`omp-eso` is stolen (e.g., via a container escape from a session pod to the node's
metadata server after bypassing NetworkPolicy, or via a GKE node compromise). This
is a lateral movement risk in multi-service GCP projects.

**Fix:** Use IAM Conditions to restrict the binding to labeled secrets, or bind
`secretAccessor` on individual secret resources rather than at the project level:

```bash
# Option A: IAM Condition (requires GCP IAM Conditions support)
gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
    --member="serviceAccount:${SA_ESO}" \
    --role="roles/secretmanager.secretAccessor" \
    --condition='expression=resource.name.startsWith("projects/PROJECT_NUMBER/secrets/") && resource.labels.omp_vault == "true",title=omp-secrets-only'

# Option B: bind per-secret in vault-add
gcloud secrets add-iam-policy-binding "${gsm_id}" \
    --project="${GCP_PROJECT}" \
    --member="serviceAccount:${SA_ESO}" \
    --role="roles/secretmanager.secretAccessor"
```

Option B is the most restrictive and is straightforward to add in `cmd_vault_add`
(after the secret is created at line 488–495).

─

### F04 — Medium — ESO Helm chart installed without version pin

**File:** `administrator.sh:279–284`

```bash
helm repo add external-secrets https://charts.external-secrets.io --force-update
helm upgrade --install external-secrets external-secrets/external-secrets \
    -n external-secrets --create-namespace \
    --set installCRDs=true \
    --set "serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account=${SA_ESO}" \
    --wait
```

No `--version` is specified. Every `./administrator.sh bootstrap` run installs
whatever the Helm registry serves as the latest ESO release. A breaking chart update
(e.g., renamed CRD fields, changed RBAC, altered SA name format) can silently break
credential sync for all future sessions, and a chart with a security regression ships
without review.

**Impact:** Unintended ESO upgrade on every `bootstrap` invocation; supply-chain
exposure to a compromised Helm chart repository.

**Fix:** Pin the chart version and verify:
```bash
helm upgrade --install external-secrets external-secrets/external-secrets \
    --version 0.10.7 \          # pin to a reviewed version
    ...
```
Record the pinned version in a comment alongside the install command so upgrades are
explicit decisions.

─

### F05 — Medium — OCI image tags default to `latest` (no content pinning)

**Files:**
- `administrator.sh:61` — `OMP_IMAGE_TAG="${OMP_IMAGE_TAG:-latest}"`
- `operator/session_operator.py:28–30` — default `"ghcr.io/james-nesbitt/collab-agent/omp-session:latest"`
- `k8s/operator-deploy.yaml:19,23` — image value `"${OMP_REGISTRY}/omp-operator:${OMP_IMAGE_TAG}"`

The operator and session images are referenced by mutable tag. `imagePullPolicy: Always`
(operator-deploy.yaml:22; session_operator.py:299) ensures the latest tag is always
fetched, which means a malicious push to the `ghcr.io/james-nesbitt/collab-agent`
namespace — whether by compromising the CI pipeline, the GitHub account, or the GHCR
token — is deployed automatically:

- Operator: on the next pod restart or deployment rollout.
- Session: on every new session creation (operator creates a fresh pod each time).

There is no `imagePullSecret` configured, confirming the images are publicly accessible.
Any GHCR account holder with push access to this repo can replace the production images.

**Impact:** Supply-chain code execution inside session pods and the operator with the
elevated ClusterRole described in F02.

**Fix:** Pin images by SHA-256 digest in all manifests and in the Python default.
After a successful CI build, capture the digest and commit it:
```
ghcr.io/james-nesbitt/collab-agent/omp-session@sha256:<digest>
```
Use a `renovate.json` or Dependabot config to automate digest updates from CI.

─

### F06 — Medium — Collab join link stored in plain-text CR status / `kubectl` table column

**Files:**
- `k8s/crd-session.yaml:26–29` (additionalPrinterColumns LINK column)
- `operator/session_operator.py:526` (`patch.status["joinLink"] = link`)

The operator captures the omp collab join link via `pods/exec` and writes it to
`status.joinLink`:

```python
patch.status["joinLink"] = link   # session_operator.py:526
```

The CRD schema registers this field as an `additionalPrinterColumn`:
```yaml
- name: LINK
  jsonPath: .status.joinLink
  type: string
```

This causes the link to appear as a literal column in `kubectl get sessions` output.

RULES.md (lines 18–19) states explicitly: *"Treat the collab join link as a secret.
Anyone with the link joins inside the credential trust boundary and sees everything on
the host's screen."* Yet the link is stored like any other status field and printed
without restriction to anyone who can `get` or `list` Session resources in `omp-system`.
The operator RBAC, administrator accounts, and any CI/CD pipeline with cluster access
can trivially obtain it.

A view-only link (`status.viewLink`) is additionally captured for non-view sessions
(lines 532–535), also in plain text.

**Impact:** Unauthorized collab participants who obtain a `kubectl get sessions` print-out
(e.g., from a log aggregator, a screenshot, a CI step) gain live session access and can
observe all injected credential values that the host agent handles.

**Fix options:**
1. Remove `joinLink` and `viewLink` from `additionalPrinterColumns` in the CRD so they
   do not appear in default `kubectl get` output.
2. Store only a truncated reference (e.g., a UUID) in the CR status and keep the actual
   link in a K8s Secret within the session namespace, readable only by the session
   namespace's SA.
3. Require explicit `kubectl get session <name> -o jsonpath='{.status.joinLink}'` for
   retrieval, which at least requires deliberate intent rather than appearing in table
   output.

─

### F07 — Medium — RFC 6598 CGNAT range (100.64.0.0/10) not excluded from egress HTTPS policy

**File:** `operator/session_operator.py:222–236`

```python
"ipBlock": {
    "cidr": "0.0.0.0/0",
    "except": [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.169.254/32",
    ],
}
```

The allow-egress-https NetworkPolicy blocks RFC 1918 private ranges and the GCE
metadata server. It does not block `100.64.0.0/10` (RFC 6598, IETF shared address
space / carrier-grade NAT). GKE uses `100.64.0.0/10` for internal Pod-to-Service and
intra-cluster traffic in some configurations (particularly with VPC-native clusters and
certain versions of GKE Autopilot). Addresses in this range that are reachable over
TCP 443 could be internal cluster services (e.g., the Kubernetes API server's internal
service IP `10.96.0.1` in standard GKE, but the broader issue is that CGNAT ranges may
host cluster infrastructure in non-standard or future GKE topologies).

**Impact:** Session pods may be able to reach internal cluster services on TCP 443
that are addressed in the `100.64.0.0/10` block, potentially including the Kubernetes
API server if its service endpoint is in this range, bypassing the intent of the
metadata-server block.

**Fix:** Add `"100.64.0.0/10"` to the `except` list in `_network_policies()`:
```python
"except": [
    "10.0.0.0/8",
    "100.64.0.0/10",   # RFC 6598 CGNAT / GKE intra-cluster
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.169.254/32",
],
```

─

### F08 — Medium — k8s manifests contain raw `${VAR}` literals — unsafe to apply directly

**Files:**
- `k8s/operator-rbac.yaml:14` — `iam.gke.io/gcp-service-account: "omp-operator@${GCP_PROJECT}.iam.gserviceaccount.com"`
- `k8s/operator-deploy.yaml:19,23` — `image: "${OMP_REGISTRY}/omp-operator:${OMP_IMAGE_TAG}"`
- `k8s/clustersecretstore.yaml:8` — `projectID: "${GCP_PROJECT}"`

These files are intended to be rendered via `render()` / `envsubst` before being piped
to `kubectl apply`. If an operator or CI step applies them directly with
`kubectl apply -f k8s/`, the literal placeholder strings are written into the cluster:

- The Workload Identity annotation on `omp-operator` SA becomes
  `omp-operator@${GCP_PROJECT}.iam.gserviceaccount.com` — not a valid GCP SA email.
  Workload Identity fails silently; the operator pod loses its GCP cloud identity and
  GSM metadata listing stops working.
- The operator Deployment references image `"${OMP_REGISTRY}/omp-operator:${OMP_IMAGE_TAG}"`,
  which Kubernetes cannot pull. The operator pod enters `ImagePullBackOff` with no
  clear error message pointing to the substitution failure.

None of the files carry a warning header.

**Impact:** Silently broken cluster state that looks like an image or network problem
rather than a manifest authoring problem. In the WI case, the operator loses its GCP
identity and future GSM-backed sessions start without credentials.

**Fix:** Add a guard comment at the top of each templated file:
```yaml
# DO NOT apply directly — contains ${VAR} placeholders.
# Use: ./administrator.sh bootstrap  (or setup/credentials as appropriate)
```
Consider renaming to `*.tmpl.yaml` to make the template nature structurally obvious.

─

### F09 — Low — Session pod auto-mounts an unused Kubernetes service account token

**Files:** `operator/session_operator.py:113–118`, `283–321`

The `_service_account()` builder (line 113) creates `omp-session` without setting
`automountServiceAccountToken: false`:
```python
return k8s.V1ServiceAccount(
    metadata=k8s.V1ObjectMeta(name="omp-session", namespace=ns),
)
```

The `_pod()` builder (line 283) similarly omits
`automount_service_account_token=False` from `k8s.V1PodSpec`. Kubernetes therefore
auto-mounts a projected service account token at
`/var/run/secrets/kubernetes.io/serviceaccount/token` inside every session container.

`omp-session` has no RBAC bindings beyond cluster defaults, so the token's practical
power is limited. However:

1. The omp agent running inside the pod is not a trusted Kubernetes client. It has
   access to a valid cluster API token without any operational need for it.
2. The allow-egress-https NetworkPolicy permits TCP 443 to public IP addresses. If the
   GKE cluster's API server endpoint is public (which is the default — `cmd_provision`
   does not pass `--enable-private-endpoint`), the session pod can reach the API server
   over the internet and authenticate as `omp-session`.
3. The token is rotated automatically by Kubernetes but is present for the full session
   lifetime.

**Impact:** An agent that is prompted to call the Kubernetes API (deliberately or via
prompt injection) can authenticate. Low privilege, but unnecessary attack surface.

**Fix:**
```python
# _service_account()
return k8s.V1ServiceAccount(
    metadata=k8s.V1ObjectMeta(name="omp-session", namespace=ns),
    automount_service_account_token=False,
)

# _pod() — V1PodSpec
spec=k8s.V1PodSpec(
    service_account_name="omp-session",
    automount_service_account_token=False,
    ...
)
```

─

### F10 — Low — `resource_exists` uses unquoted `${subcmd}` variable

**File:** `lib/common.sh:37–41`

```bash
resource_exists() {
    local subcmd=$1; shift
    local name=$1; shift
    gcloud ${subcmd} describe "${name}" "$@" ...
}
```

`${subcmd}` is intentionally unquoted to allow word-splitting of multi-word gcloud
subcommands such as `"container clusters"` and `"iam service-accounts"`. All current
call sites pass hardcoded strings from within `administrator.sh`, so there is no
immediate injection path from user input. However:

1. The pattern establishes a convention that breaks immediately if `resource_exists` is
   ever called with a variable that holds an externally-supplied string.
2. Shellcheck flags this as SC2086; automated linters will produce false-negative passes
   because the string is hardcoded at call sites today.

**Impact:** Low — currently safe. Becomes High if a future caller passes user-controlled
input.

**Fix:** Refactor to an array:
```bash
resource_exists() {
    # subcmd is passed as separate words: resource_exists container clusters "$name"
    local name="${1}"; shift
    gcloud "$@" describe "${name}" --project="${GCP_PROJECT}" \
        --format="value(name)" 2>/dev/null | grep -q .
}
# Call site:
resource_exists "${CLUSTER_NAME}" container clusters --zone="${ZONE}"
```
Or keep the current signature but enforce quoting via shellcheck directives and a
`# shellcheck disable=SC2086` comment with an explicit risk explanation.

─

### F11 — Low — Operator Deployment lacks container securityContext

**File:** `k8s/operator-deploy.yaml:17–34`

The operator Deployment manifest specifies resource limits but no `securityContext`:

```yaml
containers:
  - name: operator
    image: "${OMP_REGISTRY}/omp-operator:${OMP_IMAGE_TAG}"
    imagePullPolicy: Always
    env: [...]
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits:   {cpu: 500m, memory: 256Mi}
    # No securityContext here or at pod level
```

The operator Dockerfile runs as user `omp` (a non-root account created in the image),
so in practice the process starts as UID 1000. But without `runAsNonRoot: true` and
`allowPrivilegeEscalation: false` in the pod/container securityContext, GKE has no
enforcement layer. A future image change that sets `USER root` would not be caught.
Similarly, there are no `capabilities.drop`, no `seccompProfile`, and no
`readOnlyRootFilesystem`.

**Impact:** Defense-in-depth gap; operator container is less restricted than the session
pod it manages.

**Fix:**
```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: operator
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        readOnlyRootFilesystem: true
```

─

### F12 — Low — Session namespaces created without Pod Security Admission labels

**File:** `operator/session_operator.py:104–110`

```python
def _namespace(ns: str, session_name: str) -> k8s.V1Namespace:
    return k8s.V1Namespace(
        metadata=k8s.V1ObjectMeta(
            name=ns,
            labels={"omp.mirantis.io/session": session_name},
        )
    )
```

The namespace carries only the session label. GKE 1.25+ ships with Pod Security
Admission (PSA) enabled. Without a `pod-security.kubernetes.io/enforce` label, the
namespace defaults to the `privileged` enforcement mode, meaning PSA places no
restrictions on pods created in the namespace. The security context applied by
`_pod()` is enforced only because the operator's Python code constructs it — there is
no independent enforcement layer that would reject a pod without `runAsNonRoot` or
with `privileged: true` if such a pod were submitted by another path.

**Impact:** Defense-in-depth gap. An actor with `pods: create` in a session namespace
(e.g., via a compromised operator, or a misconfigured RBAC grant) can submit a
privileged pod without restriction.

**Fix:** Add a PSA label at namespace creation time:
```python
labels={
    "omp.mirantis.io/session": session_name,
    "pod-security.kubernetes.io/enforce": "restricted",
    "pod-security.kubernetes.io/enforce-version": "latest",
},
```
Note: `restricted` policy requires `seccompProfile: RuntimeDefault` or `Unconfined` to
be explicit. Since session pods legitimately require `Unconfined` (F11 / rootless
engines), use the `baseline` level if `restricted` rejects session pods due to the
seccomp requirement:
```python
"pod-security.kubernetes.io/enforce": "baseline",
```

─

### F13 — Low — Agent guidance does not warn against `set -x` / `bash -x`

**Files:** `platform/RULES.md`, `platform/skills/credential-access/SKILL.md`

Both documents correctly warn against `curl -v` / `--trace` (which print the
`Authorization` header). `mirantis-services/SKILL.md:33` repeats the curl warning.
Neither document mentions the equivalent shell-level risk: `set -x`, `bash -x`,
`bash -v`, or any shell that starts with `#!/bin/bash -x`. When a script runs with
xtrace, every expanded variable value — including `$GITHUB_TOKEN`,
`$ATLASSIAN_TOKEN`, and any other injected credential — is written to stderr/stdout.
Because `secrets.enabled` obfuscation is model-side, xtrace output bypasses the
`#XXXX#` placeholder mechanism and writes the real value to the on-disk transcript
and every guest screen.

**Impact:** An agent instructed to "debug the script" by adding `set -x` inadvertently
de-obfuscates all referenced credential values.

**Fix:** Add to `platform/RULES.md` after the existing bullet on `-v`/`--trace`:
```
- **Never use `set -x`, `bash -x`, `bash -v`, or xtrace in any script that has
  access to credential variables.** Shell xtrace expands every variable in real time
  and writes the value to output, bypassing `#XXXX#` obfuscation. Debug logic by
  inserting `echo` statements that do not expand credential variables.
```
Add the same note to `credential-access/SKILL.md`.

─

### F14 — Info — Base images use mutable tags without digest pins

**Files:** `Dockerfile:1`, `operator/Dockerfile:1`

```dockerfile
FROM ubuntu:24.04
FROM python:3.12-slim
```

Both base images are referenced by floating tag. A Docker Hub push of a patched or
malicious layer to either tag would be pulled on the next `docker build` without
notice.

**Impact:** Unintended OS-level changes on rebuild; supply-chain exposure if the base
image registries are compromised.

**Fix:** Pin by digest:
```dockerfile
FROM ubuntu:24.04@sha256:<digest>
FROM python:3.12-slim@sha256:<digest>
```
Use Dependabot or Renovate to automate digest updates.

─

### F15 — Info — GCP project ID hard-coded as default in `lib/common.sh`

**File:** `lib/common.sh:11`

```bash
GCP_PROJECT="${GCP_PROJECT:-tools-348616}"
```

Running any `administrator.sh` subcommand without setting `GCP_PROJECT` targets the
project `tools-348616`. A developer working from a fresh shell or a CI runner with
an unconfigured environment will silently operate on what may be a production project.

**Impact:** Accidental infrastructure changes in the wrong project.

**Fix:** Remove the default and `die` if `GCP_PROJECT` is unset:
```bash
GCP_PROJECT="${GCP_PROJECT:?GCP_PROJECT must be set}"
```

─

### F16 — Info — ExternalSecret objects hard-coded to `external-secrets.io/v1`

**File:** `operator/session_operator.py:147`

```python
"apiVersion": "external-secrets.io/v1",
```

The `eso_api_version()` function in `administrator.sh` (lines 92–102) detects whether
ESO serves `v1` or `v1beta1` and uses it for ClusterSecretStore creation. The Python
operator always uses `v1` when constructing ExternalSecret objects. If the cluster
runs an older ESO version that only serves `v1beta1`, all ExternalSecrets fail to be
created and every session starts without credentials (`omp-creds` Secret is
`optional: true` in the pod spec, so the pod still starts — silently missing all
injected credentials).

**Impact:** Operational: sessions run without credentials with no clear error surfaced
to the user.

**Fix:** Pass the detected ESO API version as an operator environment variable
(set during `administrator.sh setup`) and read it in `session_operator.py`:
```python
OMP_ESO_API_VERSION: str = os.environ.get("OMP_ESO_API_VERSION", "external-secrets.io/v1")
```

─

## Strengths

The following security properties are correctly implemented and verified against the
source:

**Credential handling (vault-add):**
`cmd_vault_add` (administrator.sh:472–506) reads the secret value via `cat` from stdin
and passes it to GSM exclusively via `--data-file=-` (line 499–503). The value is never
echoed, never placed in a shell variable that is printed, and never appears in process
arguments. `valid_token()` (line 105) validates the entry name to
`^[A-Za-z0-9_/-]+$` before constructing the GSM secret ID, preventing shell
metacharacter injection in the GSM create/add commands.

**`set -euo pipefail` throughout:**
All three shell scripts (`administrator.sh:45`, `lib/common.sh` sourced into it,
`docker/entrypoint.sh:2`) run with `set -euo pipefail`. Unbound variable references
and pipeline failures abort the script rather than silently continuing with empty values.

**NetworkPolicy: deny-all + targeted egress:**
`_network_policies()` (session_operator.py:179–237) applies three policies in every
session namespace: a default-deny for both Ingress and Egress, a DNS egress restricted
to `kube-system`, and an HTTPS egress to public IPs that explicitly excludes all RFC
1918 ranges and `169.254.169.254/32`. GKE `--enable-dataplane-v2` (administrator.sh:179)
ensures Cilium enforces these policies; without eBPF dataplane, `kube-proxy` would not
enforce `NetworkPolicy` objects.

**GCE metadata server explicitly blocked:**
`169.254.169.254/32` appears in the NetworkPolicy `except` list (session_operator.py:230).
The metadata server is the primary route to Workload Identity token exfiltration from
a session pod. The session SA has no WI annotation (confirmed in the `_service_account`
comment, session_operator.py:114), so even if the block were absent the token would
not carry GCP cloud privileges — but the explicit block is correct defense-in-depth.

**Workload Identity — no key files:**
ESO and operator GCP SAs are bound via WI annotations
(`k8s/operator-rbac.yaml:14`; `administrator.sh:221–234`). No `credentials.json`, no
`GOOGLE_APPLICATION_CREDENTIALS` paths, and no key downloads appear anywhere in the
codebase. The GCP SAs are correctly scoped: ESO has `secretAccessor` (for values),
operator has only `secretmanager.viewer` (for metadata listing, never values).

**Session pod runs as UID 1000, non-root:**
`runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, and `fsGroup: 1000` are
set at both the pod and container level (session_operator.py:288–314). `privileged:
false` is the default and is not overridden. `capabilities.drop: ["ALL"]` is explicit.

**No cross-session namespace reachability:**
Each session is provisioned in an isolated `omp-session-<name>` namespace with its
own NetworkPolicy deny-all. Session pods have no ingress allowed; inter-session
communication is structurally impossible via the network layer.

**`secrets.enabled: true` in omp-config:**
The platform config baked into the image (`administrator.sh:_base_config_yml`,
lines 108–145) sets `secrets.enabled: true`. The omp agent receives
`#XXXX#` opaque placeholders rather than real credential values, substantially reducing
the risk of a model inadvertently printing a secret in visible output.

**GKE hardening flags on cluster creation:**
`cmd_provision` (administrator.sh:172–185) passes:
- `--no-enable-basic-auth` — disables username/password cluster access
- `--no-issue-client-certificate` — disables X.509 client cert auth
- `--enable-dataplane-v2` — Cilium eBPF for NetworkPolicy enforcement
- `--workload-pool` — enables Workload Identity on the cluster

**IAM paranoia check:**
`cmd_provision` (administrator.sh:244–248) fetches the project IAM policy and aborts
with an error if `allUsers` or `allAuthenticatedUsers` bindings are found, preventing
accidental public cluster exposure.

**Explicit `yes` confirmation before destroy:**
`cmd_destroy` (administrator.sh:342–343) requires the administrator to type the literal
string `yes` before deleting the cluster and SAs. Accidental invocation without
confirmation fails safely.

**Agent guidance — credential safety chain:**
`platform/RULES.md`, `platform/skills/credential-access/SKILL.md`, and
`platform/skills/mirantis-services/SKILL.md` all contain explicit, consistent
instructions: consume credentials inline in the tool command, never expand them into
output, never use `-v`/`--trace` on authenticated requests. The `mirantis-services`
skill provides `curl -o /dev/null -w '%{http_code}'` as the safe pattern for status
checks (line 43).

**Operator Python dependencies pinned:**
`operator/requirements.txt` pins `kopf==1.37.2`, `kubernetes==31.0.0`, and
`google-cloud-secret-manager==2.22.0` to exact versions. Supply-chain drift is
mitigated for the operator's Python dependencies (though no hash pinning is present).

─

## Residual Risks (by design)

The following exposures are inherent to the architecture and are not bugs; they are
documented here to inform operational decisions.

**allowPrivilegeEscalation + seccomp Unconfined on session pods:**
Session pods run rootless Docker and Podman (`docker/entrypoint.sh:31–32`). Rootless
engines require setuid `newuidmap`/`newgidmap` binaries for user-namespace UID
mapping; these fail under `allowPrivilegeEscalation: false`. The `Unconfined` seccomp
profile is needed to permit `clone(CLONE_NEWUSER)` and related user-namespace syscalls.
Both settings are documented in the `_pod` docstring (session_operator.py:241–252).
This is the minimum viable security posture for in-pod rootless container engines.

**On-disk session transcript may contain de-obfuscated credential values:**
The omp transcript is stored on the 50 GiB PVC (`omp-home`) at
`/home/omp/work/` and persists across pod restarts. RULES.md explicitly warns that
any tool result which prints a real credential value is "persisted de-obfuscated to
the session transcript on disk" (RULES.md:9–10). The PVC is backed by GCE Persistent
Disk (encrypted at rest with Google-managed keys by default), but application-level
access — via the operator's `pods/exec` capability, a direct PVC remount by any pod
the operator creates, or a GKE node compromise — exposes the full conversation history
including any de-obfuscated credentials that leaked via tool output. The only
mitigation is the agent-guidance chain (credential-safety rules) preventing such leaks
in the first place.

**Collab multi-tenancy is trust-flattened:**
All participants in a collab session (host and guests) share the same screen, the same
omp process, and all injected environment variables. Operator identities
(`OPERATOR_NAME`/`OPERATOR_EMAIL`) are advisory and unauthenticated — any collab
participant can claim any identity. A guest who joins with a host-level link
(not a view-only link) can prompt the agent to act as any operator. AGENTS.md
(lines 35–37) documents this explicitly. The `spec.view: true` flag creates a
view-only session, but the default is `false`.

**GSM secrets persist after session deletion:**
`cmd_destroy` (administrator.sh:334–367) deletes the GKE cluster and GCP SAs. It does
not delete GSM secrets. Session namespace deletion (`delete` handler,
session_operator.py:548–564) deletes only Kubernetes resources, not the underlying GSM
secret versions. The vault is intentionally durable (operator-managed secrets span
multiple sessions), but this means deprovisioning the cluster does not purge secrets
from GCP. Explicit `gcloud secrets delete` is required for a full teardown.
