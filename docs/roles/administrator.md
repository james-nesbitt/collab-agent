# Administrator Guide

You are the **administrator**. Your job is to stand up and maintain the GKE cluster,
configure the omp platform, and manage the credential vault. Once the cluster is up
and credentials are stored, you hand off to the [manager](manager.md).

Provisioning uses **Terraform** (`infra/`). Day-to-day vault/team/status operations
use **`./administrator.sh`**. Pod auth and session lifecycle use **`ompctl`**.
All cluster access is via `kubectl` (credentials from GKE) and `gcloud`. No SSH.

## Before you start

- `gcloud` installed and authenticated: `gcloud auth login`.
- `kubectl` installed.
- `terraform` (≥1.7) installed.
- Your active GCP account must be the one that will own the cluster
  (`gcloud config get-value account`). The script locks IAM access to this account and
  stores it as `ADMIN_GCP_ACCOUNT` (defaults to the currently active account).
- The defaults target project `tools-348616`, zone `europe-west1-b`. Override via env
  before running (see the end of this guide).

## 1. First time: provision the full platform

```bash
# One-time: create GCS state bucket
gcloud storage buckets create gs://<tf-state-bucket> \
  --project=<project> --location=europe-west1

# Create infra/terraform.tfvars
cat > infra/terraform.tfvars <<EOF
project           = "tools-348616"
admin_gcp_account = "jnesbitt@mirantis.com"
group_domain      = "mirantis.com"
omp_config_memory   = true
omp_config_thinking = true
EOF

# Provision everything
cd infra
terraform init -backend-config="bucket=<tf-state-bucket>"
terraform apply
```

This single `terraform apply` stands up the entire platform in one step.

What it does:
- Enables GCP APIs (`container.googleapis.com`, `secretmanager.googleapis.com`)
- Creates GKE cluster + node pool (3 × `e2-standard-4` Ubuntu nodes, Workload Identity)
- Creates GCP SAs `omp-eso` (secret accessor) and `omp-operator` (metadata viewer); adds WI bindings
- Grants `roles/container.clusterAdmin` to `admin_gcp_account`
- Installs External Secrets Operator via Helm into `external-secrets`
- Installs the `omp-platform` Helm chart: Session CRD, RBAC, operator Deployment, VAP, ClusterSecretStore, omp-config ConfigMap, admin ClusterRoleBinding

Local-model tuning (`omp_config_memory`, `omp_config_thinking`) is set in tfvars — no separate `tune` step.

**First-apply contingency:** if the helm provider can't reach the new cluster on the first pass, run `terraform apply -target=google_container_node_pool.default` then `terraform apply`.

Now store credentials and create sessions.

## 2. Store credentials

Credentials live in **GCP Secret Manager**, organised into subtrees. `vault-add`
prompts for the value interactively (hidden — never echoed, never in shell history):

```bash
./administrator.sh vault-add shared/ollama-cloud-api-key   # prompts for value
./administrator.sh vault-add users/jnesbitt/atlassian-token
```

### Subtree conventions

| Subtree | Purpose | Who gets it |
|---|---|---|
| `shared/` | Platform-wide credentials all sessions may need (e.g. Ollama Cloud key) | Any session with `spec.subtrees: ["shared"]` |
| `users/<name>/` | Personal credentials scoped to one user (Atlassian, GitHub PAT) | Only sessions that explicitly include `users/<name>` in `spec.subtrees` |


### Naming and env var derivation

The vault path becomes an env var inside the session pod: the subtree prefix is
stripped, `/` and `-` become `_`, uppercased. Examples:

| Vault path | GSM secret | Env var |
|---|---|---|
| `shared/ollama-cloud-api-key` | `shared-ollama-cloud-api-key` | `OLLAMA_CLOUD_API_KEY` |
| `users/jnesbitt/atlassian-token` | `users-jnesbitt-atlassian-token` | `ATLASSIAN_TOKEN` |
| `users/jnesbitt/github-token` | `users-jnesbitt-github-token` | `GITHUB_TOKEN` |

End entry names with a secret keyword (`token`, `key`, `secret`, `password`) so
omp's value obfuscation fires. Check what's stored (names only, never values):

```bash
./administrator.sh vault-ls               # all entries
./administrator.sh vault-ls shared        # one subtree
./administrator.sh vault-ls users/jnesbitt
```

### Injecting credentials into a session

Sessions declare what they need via `spec.subtrees`. The operator builds an
ExternalSecret; ESO syncs the values into `omp-creds` in the session namespace.
Only `omp-creds` is auto-injected — nothing else is copied unless explicitly declared.

```yaml
spec:
  subtrees: ["shared", "users/jnesbitt"]  # gets OLLAMA_CLOUD_API_KEY + ATLASSIAN_* + GITHUB_TOKEN
```

### Container images

> **Note:** Session and operator images are published to **public** GHCR packages, so
> session pods pull them with no image-pull secret. There is nothing to manage here.

## 3. Personal credentials (self-service)

Team members manage their own credentials in GSM without admin involvement:

```bash
# User adds their own credential (value prompted hidden)
GCP_PROJECT=tools-348616 OMP_ESO_SA=omp-eso@tools-348616.iam.gserviceaccount.com \
  ompctl cred add atlassian-token

# List personal credentials
GCP_PROJECT=tools-348616 ompctl cred ls
```

Credentials are stored under `users/<username>/` in GSM. Sessions request them via `spec.subtrees: ["users/<name>"]`. See `ompctl --help` for full usage.

## 4. Day to day

- **Check on it.** `./administrator.sh status` prints a cluster summary, node list, and
  all current Sessions cluster-wide.
- **Refresh kubectl credentials.** Run `gcloud container clusters get-credentials omp-cluster --zone europe-west1-b` (or `terraform output kubeconfig_command`) — useful when your kubeconfig has expired.
- **Images.** Session and operator images are built and published to GHCR by the CI
  workflow (`.github/workflows/build-images.yml`); `administrator.sh` does not build or
  push images. The GHCR packages are **public**, so session pods pull them directly with
  no image-pull secret to manage.
- **Gemini API key.** Store via `./administrator.sh vault-add shared/gemini-api-key` (prompts hidden). Add `"shared"` to session `spec.subtrees`. ESO syncs it automatically.

## 5. Tearing it down

```bash
cd infra && terraform destroy
```

This permanently deletes the cluster, the two GCP service accounts (`omp-eso`,
`omp-operator`), and their IAM bindings. Terraform prompts you to type `yes` first.

**All session namespaces, PVCs, and the GSM vault contents are deleted with the
cluster.** Back up anything you need first.

## Pointing at a different cluster

All defaults are overridable via `infra/terraform.tfvars`:

| Variable | Default | Notes |
| --- | --- | --- |
| `project` | (required) | GCP project ID |
| `zone` | `europe-west1-b` | GKE zone |
| `cluster_name` | `omp-cluster` | |
| `node_machine_type` | `e2-standard-4` | |
| `node_count` | `3` | |
| `admin_gcp_account` | (required) | Google account email |
| `group_domain` | `mirantis.com` | Google Workspace domain |
| `omp_config_memory` | `false` | Enable mnemopi memory |
| `omp_config_thinking` | `false` | Enable auto thinking level |
| `teams` | `[]` | Team slugs to onboard |

`./administrator.sh` env vars (`GCP_PROJECT`, `ZONE`, `CLUSTER_NAME`) still apply for vault/status/team operations — keep them consistent with your tfvars.

## Teams

See [docs/access-control.md](../access-control.md) for the full model. Summary:

### Prerequisite (Workspace admin)

Create Google Groups in Workspace:
- `gke-security-groups@mirantis.com` — required GKE umbrella; members are other groups
- `omp-admins@mirantis.com` — admin group; member of `gke-security-groups@`
- `omp-team-<team>@mirantis.com` — one per team; member of `gke-security-groups@`

`terraform apply` enables `--security-group=gke-security-groups@<group_domain>` on the
cluster (GKE Groups-for-RBAC) and the `omp-platform` chart adds the `omp-admins@`
ClusterRoleBinding.
Until the Workspace groups exist, all group RBAC bindings are inert — testable via
`kubectl auth can-i --as-group=`.

### Onboard a team

```bash
./administrator.sh team-add <team>    # idempotent
```

Creates namespace `omp-team-<team>`, a `sessions` CRUD Role+RoleBinding for
`omp-team-<team>@mirantis.com`, and grants `roles/container.clusterViewer` IAM so
members can `get-credentials`.

### List and remove teams

```bash
./administrator.sh team-ls
./administrator.sh team-rm <team>    # prompts; warns if session namespaces exist
```

## What you don't do

You never create or manage sessions — that is the [manager's](manager.md) job, done
directly with `kubectl`. You never build or push images — that's the GHCR CI
workflow (`.github/workflows/build-images.yml`), triggered by pushing to the repo.
For the bigger picture — how ESO syncs credentials into session namespaces, how
NetworkPolicy isolates sessions, how the collab link is captured — read
[the architecture doc](../architecture.md).
