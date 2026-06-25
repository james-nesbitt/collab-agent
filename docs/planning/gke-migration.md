# GKE migration design notes

Records decisions made during the migration from GCP VM (SSH/tmux) to GKE
(Session operator + per-session pods). See [docs/architecture.md](../architecture.md)
for the resulting design.

## Key decisions

### Operator: Python + kopf

Chosen over shell + kubectl or Go. kopf gives declarative reconcile loops, automatic
retry, and finalizer management with minimal boilerplate. Python is already in the
containerized runtime stack; no new language toolchain needed for operators.

### Vault: GCP Secret Manager + External Secrets Operator

Replaces the per-VM `pass`/GPG vault. GSM provides: at-rest encryption, IAM-gated
access, audit logging, and version history. ESO bridges GSM → K8s Secrets so pods
consume credentials via the standard `envFrom` mechanism. The manager never calls
`access_secret_version` (values never cross the laptop); the operator only calls
`list_secrets` (metadata, not values). ESO's WI-annotated SA holds the `secretAccessor`
role.

### Container engines: rootless docker + rootless podman, non-privileged, Ubuntu node pool

Session pods need docker and podman for CI/CD workloads run by the agent. Non-privileged
is required for tenant isolation (privileged = host root). Rootless engines + vfs storage
driver work in a non-privileged pod on an Ubuntu node pool (COS disables unprivileged
user namespaces). `seccompProfile: Unconfined` and `allowPrivilegeEscalation: true`
(for setuid `newuidmap`/`newgidmap`) are the documented Docker-rootless recipe.

### Model OAuth: in-session login persisted on PVC

Anthropic's device-code OAuth cannot be automated; it requires a browser on the
operator's machine. In GKE mode there is no `manager.sh`; the operator runs
`kubectl exec -it -n omp-session-NAME omp -- bash` to enter the pod and complete the
auth flow interactively. The resulting token is stored on the PVC and survives pod
restarts. Token-based providers (API keys) are stored in GSM via `vault-add`.

For token-based providers, an `omp-bootstrap-env` Secret in `omp-system` (containing
e.g. `GEMINI_API_KEY`) is copied by the operator into every session namespace
automatically and mounted via `envFrom`. This lets a session start and produce a collab
join link before Anthropic OAuth is completed; the operator authenticates interactively
from inside the collab session.

### Images: GHCR via GitHub Actions CI

Built and pushed by `.github/workflows/build-images.yml` on every change to
`Dockerfile`, `docker/`, `operator/`, `platform/`, or `session-template/`. Packages
remain private; `ghcr-pull-secret` in `omp-system` is the interim workaround. The
operator copies it into each session namespace at provision time so pods can pull images
without baking credentials into the image. When packages are eventually made public
(GitHub → Packages → package settings → Change visibility), the secret can be removed
with no code changes.

### Credential isolation: realized

The "Tier-2 per-session OS-level isolation" from `credential-isolation.md` is now
largely realized: each session runs in its own Kubernetes namespace with a per-namespace
Secret containing only that session's requested subtrees. NetworkPolicy denies all
ingress and restricts egress to DNS + HTTPS (not RFC1918 or metadata server), so a
compromised pod cannot reach other session namespaces or mint cloud credentials.

### Relay

Default: `wss://my.omp.sh` (unchanged). Set `OMP_RELAY` to self-host. NetworkPolicy
allows 443 to any internet IP rather than pinning relay IPs (relay + Anthropic + git
endpoints are dynamic).

### omp binary: compiled standalone to avoid PVC shadowing

The Dockerfile installs omp via bun into `/home/omp/.bun/bin/omp`, but the session pod
mounts a PVC at `/home/omp`, shadowing the entire home directory. Fix: `bun build
--compile` produces a self-contained ELF at `/usr/local/bin/omp` during the image build
(outside the PVC mount point). This binary has no runtime dependency on bun or
node_modules and is unaffected by the PVC mount.
