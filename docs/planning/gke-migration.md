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
operator's machine. `manager.sh login NAME` drops the operator into an interactive
`kubectl exec` for the auth flow; the resulting token is stored on the PVC and survives
pod restarts. Token-based providers (API keys) are stored in GSM via `vault-add`.

### Images: GHCR via GitHub Actions CI

Built and pushed by `.github/workflows/build-images.yml` on every change to
`Dockerfile`, `docker/`, `operator/`, `platform/`, or `session-template/`. Packages
set to public so GKE pulls anonymously (no credentials baked into images; credentials
arrive at runtime via env).

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
