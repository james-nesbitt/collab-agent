# Remote Agent Machine

A shared, always-on omp coding agent hosted on GKE. Each session runs in an isolated
Kubernetes namespace with its own credentials (synced from GCP Secret Manager), a
persistent home volume, and an outbound-only NetworkPolicy. Sessions are shared via
omp **collab** — operators join from any machine with `omp join`.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full picture.

```
infra/             — Terraform: GKE cluster + IAM + ESO + operator (Helm chart)
charts/omp-platform/ — Helm chart (operator, ESO store, omp-config ConfigMap, self-hosted relay)
relay/             — self-hosted collab relay (vendored omp relay contract + TLS/certbot)
skills/            — administrator/manager/operator SKILL.md (see AGENTS.md)
administrator.sh   — admin CLI: vault (credentials), teams, status, credentials (kubeconfig), session-transfer
ompctl             — self-service credential + session CLI
lib/common.sh      — shared config + helpers (sourced)
Dockerfile         — session image (rootless docker+podman + mise/bun/omp)
docker/            — entrypoint.sh
operator/          — kopf Session operator (Python)
k8s/               — CRD, RBAC, operator Deployment, ESO ClusterSecretStore
platform/          — global agent context (baked into image)
session-template/  — per-session .omp/ seed (baked into image)
.github/           — CI: build + push images to GHCR
docs/              — architecture, relay, role guides, planning
```

## Quickstart

### 1. Stand up the infrastructure (administrator)

```bash
# Prerequisites: gcloud + kubectl + terraform (>=1.7) + helm, authenticated; a GCS bucket for TF state
cd infra && terraform init -backend-config="bucket=<state-bucket>" && terraform apply
# One apply provisions the GKE cluster + GCP SAs + IAM + ESO + operator (omp-platform Helm chart)
```

### 2. Configure the platform and vault (administrator)

```bash
# Platform config/tuning lives in infra/terraform.tfvars (e.g. omp_config_memory=true,
# omp_config_thinking=true), then `terraform apply` re-renders the omp-config ConfigMap.
# Shared platform credentials (hidden prompt -> GSM):
./administrator.sh vault-add shared/ollama-cloud-api-key   # e.g. an Ollama Cloud key
./administrator.sh vault-add shared/gemini-api-key         # model bootstrap key (sessions auto-start)
./administrator.sh vault-ls shared                         # confirm (names only, never values)
# Personal credentials are self-service via ompctl (stored under users/<you>/):
ompctl cred add atlassian-token     # -> users/<you>/atlassian-token
# Reference personal creds from a session with spec.subtrees: ["users/<name>"]
```

### 3. Launch a session (manager)

```bash
kubectl apply -f - <<EOF
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: work
  namespace: omp-system  # Session CRs live in omp-system or omp-team-<team>
spec:
  subtrees: ["shared"]
  view: false
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Hosting session/work -n omp-system --timeout=180s
# Sessions start authenticated when shared/gemini-api-key (or another provider key) is in the
# vault, so the join link is ready immediately. Complete interactive provider auth with:
#   ompctl auth work anthropic   # device code — visit the URL in your browser
# (token persists on the session PVC). Providers: anthropic · gcloud · aws · az · gh.
# Tiny-model weights (session titles, memory) are baked into the image — no downloads needed.
kubectl get session work -n omp-system -o jsonpath='{.status.joinLink}'  # prints join link
```

### 4. Join as an operator

```bash
omp join "<link from collab>"
```

No omp installed? Paste the link at the browser URL the manager gave you alongside
it — collab routes through our self-hosted relay (see [docs/relay.md](docs/relay.md)),
not `my.omp.sh`.

### 5. Tear down

```bash
kubectl delete session work -n omp-system  # delete session + namespace + PVC
cd infra && terraform destroy              # delete cluster + SAs + IAM bindings
```

## Configuration

Cluster and image settings are primarily set via `infra/terraform.tfvars` now. A few
environment variables tune the `administrator.sh` / `ompctl` helpers:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GCP_PROJECT` | `tools-348616` | GCP project |
| `ZONE` | `europe-west1-b` | GKE zone |
| `CLUSTER_NAME` | `omp-cluster` | GKE cluster name |
| `ADMIN_GCP_ACCOUNT` | current gcloud account | Account granted cluster-admin |
| `OMP_GROUP_DOMAIN` | `mirantis.com` | Workspace domain for RBAC groups |

## Roles

Agent-consumable skills: see [AGENTS.md](AGENTS.md) → [`skills/`](skills/). Long-form
guides behind each skill:

- [Administrator guide](docs/roles/administrator.md)
- [Manager guide](docs/roles/manager.md)
- [Operator guide](docs/roles/operator.md)
- [Access control](docs/access-control.md) — GCP IAM + Kubernetes RBAC + team onboarding
  (requires `gke-security-groups@mirantis.com` + per-team Google Groups in Workspace)
