# Administrator Guide

You are the **administrator**. Your job is to stand up and maintain the GKE cluster,
configure the omp platform, and manage the credential vault. Once the cluster exists,
the platform runtime (ESO, CRD, operator) is bootstrapped, the platform is configured
(`setup`), and credentials are stored (`vault-add`), you hand off to the
[manager](manager.md) who creates and shares sessions.

Everything you do goes through **`administrator.sh`**, run from this repo on your
laptop. There is no VM, no static IP, and no SSH. All cluster access is via
`kubectl` (credentials fetched from GKE) and `gcloud`.

## Before you start

- `gcloud` installed and authenticated: `gcloud auth login`.
- `kubectl` installed.
- `helm` installed (v3+).
- Your active GCP account must be the one that will own the cluster
  (`gcloud config get-value account`). The script locks IAM access to this account and
  stores it as `ADMIN_GCP_ACCOUNT` (defaults to the currently active account).
- The defaults target project `tools-348616`, zone `europe-west1-b`. Override via env
  before running (see the end of this guide).

## 1. First time: create the cluster + IAM

```bash
./administrator.sh provision
```

This is idempotent — re-running is safe if anything was already created.

What it does:

- Enables GCP APIs (`container.googleapis.com`, `secretmanager.googleapis.com`).
- Creates the GKE Standard cluster `omp-cluster` (3 × `e2-standard-4` Ubuntu nodes,
  Dataplane V2, Workload Identity).
- Creates two GCP service accounts:
  - `omp-eso` — ESO reads credential values from GSM (`roles/secretmanager.secretAccessor`).
  - `omp-operator` — operator lists secret metadata in GSM (`roles/secretmanager.viewer`).
- Adds Workload Identity bindings so the GKE pods impersonate those GCP SAs without
  any key file.
- Grants `roles/container.admin` to `ADMIN_GCP_ACCOUNT` only; refuses to proceed if
  `allUsers` or `allAuthenticatedUsers` bindings are found on the project.

When it finishes, run `bootstrap` next.

## 2. First time: install the platform runtime

```bash
./administrator.sh bootstrap
```

This installs the cluster-side platform components. Run once; idempotent.

What it does:

- Fetches cluster credentials (`gcloud container clusters get-credentials`).
- Binds `ADMIN_GCP_ACCOUNT` to RBAC `cluster-admin`.
- Installs External Secrets Operator (ESO) via Helm into `external-secrets`,
  annotating its service account with the `omp-eso` GCP SA for Workload Identity.
- Applies `k8s/crd-session.yaml`, `k8s/operator-rbac.yaml`, `k8s/operator-deploy.yaml`
  (env-substituting `GCP_PROJECT`, `OMP_REGISTRY`, `OMP_IMAGE_TAG` first).
- Waits for the `omp-operator` Deployment (ns `omp-system`) and ESO to become Available.
- Prints `BOOTSTRAP_OK`.

Now run `setup`.

## 3. First time: configure the platform

```bash
./administrator.sh setup
```

One idempotent command does two things:

1. Applies the ESO `ClusterSecretStore omp-gsm` (backed by GCP Secret Manager via
   Workload Identity) — the bridge between GSM and per-session Kubernetes Secrets.
2. Creates (or patches) the master `omp-config` ConfigMap in `omp-system` with:
   - Global secret obfuscation (`secrets.enabled: true`) so credential values are
     replaced with `#XXXX#` before any text reaches the model.
   - `modelRoles`: default/plan `google/gemini-3.1-pro-preview`, slow `google/gemini-1.5-pro`, smol `google/gemini-1.5-flash`.
   - Portable agent tuning (editor/task defaults).

You'll see `SETUP_OK`. Re-run any time you change `platform/` files or rotate config
— it overwrites the ConfigMap; running pods pick up the new config on next restart.

### Optional: tune the agent's local models

Two extra capabilities are off by default:

```bash
./administrator.sh tune --memory      # mnemopi long-term memory across sessions
./administrator.sh tune --thinking    # automatic per-turn thinking-level selection
./administrator.sh tune               # both
```

`tune` patches the master `omp-config` ConfigMap. Running pods pick it up on next
restart (`kubectl delete pod omp -n omp-session-NAME` to force it immediately).
Tiny-model weights (`lfm2-350m` ~212 MB for titles, `qwen3-1.7b` ~1.1 GB for memory/thinking)
are baked into the session image and seeded to each session PVC on first pod start — no downloads
at runtime. `tune` patches the master ConfigMap in `omp-system` only; to propagate to a running
session, also patch its session-namespace ConfigMap (`omp-config` in `omp-session-*`) and restart
the pod. Expect `TUNE_OK`.

## 4. Store credentials

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

The `services/` subtree is retired — it conflated platform and personal credentials.

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

### GHCR image pull secret

Keep the pull secret current whenever your GitHub token rotates (needs `read:packages` scope):

```bash
./administrator.sh github-pull-secret   # auto-detects username + token from gh CLI
```

Propagates automatically to all running session namespaces.

## 4b. User credential namespaces

For personal credentials that team members manage themselves without admin involvement:

```bash
./administrator.sh user-add <name>     # creates omp-user-<name> namespace + IAM
./administrator.sh user-rm <name>      # removes namespace + IAM (prompts)
```

Once onboarded, the user creates their own K8s Secrets:

```bash
# Values prompted interactively (hidden) — never appear in process args or shell history
./administrator.sh user-cred-add atlassian ATLASSIAN_TOKEN ATLASSIAN_EMAIL
./administrator.sh user-cred-add github-token GITHUB_TOKEN   # or: github-user-cred
./administrator.sh user-cred-ls                              # list names + keys, never values
```

Users reference secrets in Session CRs as `credentialSecrets: ["<name>/<secret>"]`.
The operator resolves `omp-user-<name>` and copies the named Secret into the session pod
namespace at provision time. No admin involvement needed for rotation.

## 5. Day to day

- **Check on it.** `./administrator.sh status` prints a cluster summary, node list, and
  all current Sessions cluster-wide.
- **Refresh kubectl credentials.** `./administrator.sh credentials` runs the
  `get-credentials` call — useful when your kubeconfig has expired.
- **Images.** Session and operator images are built and published to GHCR by the CI
  workflow (`.github/workflows/build-images.yml`); `administrator.sh` does not build or
  push images. GHCR packages are currently **private**; the operator automatically copies
  `ghcr-pull-secret` from `omp-system` into each session namespace so pods can pull
  images. To remove this dependency, make the packages public on GitHub (repo → Packages →
  package settings → Change visibility to Public) and delete the `ghcr-pull-secret` Secret
  from `omp-system`.
- **Bootstrap model credentials.** Create `omp-bootstrap-env` in `omp-system` with any
  API keys needed for session startup (e.g. `GEMINI_API_KEY`). The operator copies this
  Secret into every session namespace automatically. This allows sessions to start and
  generate a join link before Anthropic OAuth is completed:
  ```bash
  kubectl create secret generic omp-bootstrap-env -n omp-system \
    --from-literal=GEMINI_API_KEY=<key>
  ```

## 6. Tearing it down

```bash
./administrator.sh destroy
```

This permanently deletes the cluster, the two GCP service accounts (`omp-eso`,
`omp-operator`), and their IAM bindings. It prompts you to type `yes` first.

**All session namespaces, PVCs, and the GSM vault contents are deleted with the
cluster.** Back up anything you need first.

## Pointing at a different cluster

Every default is overridable by environment variable for a single command:

```bash
CLUSTER_NAME=omp-staging ZONE=us-central1-a ./administrator.sh provision
```

| Variable | Default | When it matters |
| --- | --- | --- |
| `GCP_PROJECT` | `tools-348616` | always |
| `ZONE` / `REGION` | `europe-west1-b` / `europe-west1` | always |
| `CLUSTER_NAME` | `omp-cluster` | always |
| `NODE_MACHINE_TYPE` | `e2-standard-4` | `provision` only |
| `ADMIN_GCP_ACCOUNT` | active gcloud account | `provision`, `bootstrap` |
| `OMP_REGISTRY` | `ghcr.io/james-nesbitt/collab-agent` | `bootstrap` |
| `OMP_IMAGE_TAG` | `latest` | `bootstrap` |
| `OMP_GROUP_DOMAIN` | `mirantis.com` | `provision`, `bootstrap`, `team-add/rm` |
| `SUBTREE` | `services` | `vault-add` default subtree |

## Teams

See [docs/access-control.md](../access-control.md) for the full model. Summary:

### Prerequisite (Workspace admin)

Create Google Groups in Workspace:
- `gke-security-groups@mirantis.com` — required GKE umbrella; members are other groups
- `omp-admins@mirantis.com` — admin group; member of `gke-security-groups@`
- `omp-team-<team>@mirantis.com` — one per team; member of `gke-security-groups@`

`provision` enables `--security-group=gke-security-groups@${OMP_GROUP_DOMAIN}` on the
cluster (GKE Groups-for-RBAC). `bootstrap` adds the `omp-admins@` ClusterRoleBinding.
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
