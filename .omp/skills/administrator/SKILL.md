---
name: administrator
description: Act as the administrator for the GKE cluster from this repo — provision the cluster + IAM, bootstrap the platform runtime (ESO, operator), check status, get credentials, and destroy. Use when the user asks to create, stand up, bootstrap, check on, get credentials for, or tear down the GKE cluster. This is infrastructure only; for omp config, the vault, or sessions use the `manager` skill.
---

# Administrator

You drive the **GKE cluster lifecycle** via `./administrator.sh`, run from the repo root.
This role is pure infrastructure: make the cluster and platform runtime exist. Anything
about omp itself — secrets, the credential store, sessions, collab — is the
[`manager`](skill://manager) skill.

Full reference: read `docs/roles/administrator.md`.

## Preconditions

- `gcloud`, `kubectl`, and `helm` are installed and `gcloud` is authenticated.
- Project/cluster defaults: `tools-348616` / `omp-cluster` / zone `europe-west1-b`.
  Override with env vars (`GCP_PROJECT`, `CLUSTER_NAME`, `ZONE`, `REGION`,
  `NODE_MACHINE_TYPE`, `ADMIN_GCP_ACCOUNT`, `OMP_REGISTRY`, `OMP_IMAGE_TAG`).

## Command map

| Intent | Command |
| --- | --- |
| Create cluster + GCP SAs + IAM (once) | `./administrator.sh provision` |
| Install ESO + CRD + operator on cluster | `./administrator.sh bootstrap` |
| Fetch kubectl credentials | `./administrator.sh credentials` |
| Cluster + node + session status | `./administrator.sh status` |
| Permanently delete cluster + SAs + IAM | `./administrator.sh destroy` |

`provision`, `bootstrap`, and `credentials` are idempotent. After `bootstrap`, hand off:
the `manager` skill runs `./manager.sh setup`.

## Workflows

- **Stand up from scratch:** `provision` → `bootstrap` (confirm `BOOTSTRAP_OK`), then
  tell the user to use the manager skill for `setup`.
- **Inspect:** `status` for cluster state + nodes + sessions; `credentials` to refresh
  kubectl context.

## Guardrails

- `destroy` is irreversible and deletes the cluster + all session PVCs — it prompts for
  `yes`; surface the warning to the user before running.
- Images come from GHCR CI; this role never builds or pushes images.
- Do **not** configure omp, the credential store, or sessions. Switch to `manager`.
- These scripts never push or open PRs; follow the repo git rules for any commits.
