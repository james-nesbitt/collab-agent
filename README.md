# Remote Agent Machine

A shared, always-on omp coding agent hosted on GKE. Each session runs in an isolated
Kubernetes namespace with its own credentials (synced from GCP Secret Manager), a
persistent home volume, and an outbound-only NetworkPolicy. Sessions are shared via
omp **collab** — operators join from any machine with `omp join`.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full picture.

```
administrator.sh  — GKE cluster + IAM lifecycle
manager.sh        — GSM vault + omp config + Session lifecycle
lib/common.sh     — shared config + helpers (sourced)
Dockerfile        — session image (rootless docker+podman + mise/bun/omp)
docker/           — entrypoint.sh
operator/         — kopf Session operator (Python)
k8s/              — CRD, RBAC, operator Deployment, ESO ClusterSecretStore
platform/         — global agent context (baked into image)
session-template/ — per-session .omp/ seed (baked into image)
.github/          — CI: build + push images to GHCR
docs/             — architecture, role guides, planning
```

## Quickstart

### 1. Stand up the infrastructure (administrator)

```bash
# Prerequisites: gcloud + kubectl + helm, authenticated
./administrator.sh provision   # GKE cluster + GCP SAs + IAM
./administrator.sh bootstrap   # ESO + CRD + operator
```

### 2. Configure the platform and vault (manager)

```bash
./manager.sh setup             # ESO ClusterSecretStore + omp-config ConfigMap
printf '%s' "$GITHUB_TOKEN" | ./manager.sh vault-add services/github/token
./manager.sh vault-ls          # confirm
```

### 3. Launch a session

```bash
./manager.sh new work --subtree services
./manager.sh login work        # Anthropic OAuth (persists on PVC)
./manager.sh collab work       # prints: omp join "..."
```

### 4. Join as an operator

```bash
omp join "<link from collab>"
```

No omp installed? Paste the link at `my.omp.sh`.

### 5. Tear down

```bash
./manager.sh kill work         # delete session + namespace + PVC
./administrator.sh destroy     # delete cluster + SAs + IAM bindings
```

## Configuration

All defaults are overridable via env vars. Key ones:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GCP_PROJECT` | `tools-348616` | GCP project |
| `ZONE` | `europe-west1-b` | GKE zone |
| `CLUSTER_NAME` | `omp-cluster` | GKE cluster name |
| `OMP_REGISTRY` | `ghcr.io/james-nesbitt/collab-agent` | Image registry |
| `OMP_IMAGE_TAG` | `latest` | Image tag |
| `ADMIN_GCP_ACCOUNT` | current gcloud account | Account granted cluster-admin |

## Roles

- [Administrator guide](docs/roles/administrator.md)
- [Manager guide](docs/roles/manager.md)
- [Operator guide](docs/roles/operator.md)
