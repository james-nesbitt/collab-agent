# Administrator Guide

You are the **administrator**. Your job is to stand up and maintain the GKE cluster that
everything else runs on — nothing more. Once the cluster exists and the platform runtime
(ESO, CRD, operator) is installed, you hand off to the [manager](manager.md), who owns
omp configuration, the GSM vault, and session lifecycle.

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

Now hand off: the manager runs `./manager.sh setup` (see the [manager guide](manager.md)).

## 3. Day to day

- **Check on it.** `./administrator.sh status` prints a cluster summary, node list, and
  all current Sessions cluster-wide.
- **Refresh kubectl credentials.** `./administrator.sh credentials` runs the
  `get-credentials` call — useful when your kubeconfig has expired.
- **Images.** Session and operator images are built and published to GHCR by the CI
  workflow (`.github/workflows/build-images.yml`); `administrator.sh` does not build or
  push images. Set GHCR packages to **public** after the first CI push so GKE pulls
  anonymously without an imagePullSecret (GitHub → repo → Packages → package settings).

## 4. Tearing it down

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

## What you don't do

You never configure omp, touch GSM secrets, or create sessions. The moment
`BOOTSTRAP_OK` prints, that's the [manager's](manager.md) job. If something's wrong with
a *session* (not the cluster or operator), it's a manager problem. For the bigger picture
— how ESO syncs credentials into session namespaces, how NetworkPolicy isolates sessions,
how the collab link is captured — read [the architecture doc](../architecture.md).
