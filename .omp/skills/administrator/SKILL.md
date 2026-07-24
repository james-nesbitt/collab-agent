---
name: administrator
description: Act as the administrator for the GKE cluster from this repo — provision the platform via Terraform (`infra/`), check status, get credentials, destroy, manage the credential vault (vault-add/vault-ls), and run `ompctl` for session lifecycle and auth flows. Use when the user asks to create, stand up, bootstrap, check on, get credentials for, or tear down the GKE cluster; configure omp; add/list credentials in the vault; or add/list/remove a team. For session lifecycle (new/login/attach/kill/collab) use the `manager` skill.
---

# Administrator

You drive the **GKE cluster lifecycle** via **Terraform** (`infra/`) for provisioning
and **`./administrator.sh`** for vault, team, and status operations. Session lifecycle
(applying CRs, attaching, collab links) is the [`manager`](skill://manager) skill.
Imperative pod operations (auth, port-forward, session lifecycle) use **`ompctl`**.

Full reference: read `docs/roles/administrator.md`.

## Preconditions

- `gcloud`, `kubectl`, and `terraform` (≥1.7) are installed and `gcloud` is authenticated.
- `GCP_PROJECT` and `ADMIN_GCP_ACCOUNT` set (or passed via tfvars). Defaults: project `tools-348616`, zone `europe-west1-b`.
- A GCS bucket for Terraform state must exist: `gcloud storage buckets create gs://<bucket> --project=<project>`.

## Command map

| Intent | Command |
| --- | --- |
| **Create cluster + IAM + ESO + operator (all at once)** | `cd infra && terraform init -backend-config="bucket=<state-bucket>" && terraform apply` |
| **Destroy everything** | `cd infra && terraform destroy` |
| Fetch kubectl credentials | `gcloud container clusters get-credentials omp-cluster --zone europe-west1-b` or `terraform output kubeconfig_command` |
| Cluster + node + session status | `./administrator.sh status` |
| Store a credential | `./administrator.sh vault-add shared/gemini-api-key` (prompts interactively) |
| List vault entry NAMES (never values) | `./administrator.sh vault-ls [SUBTREE]` |
| Auth a provider inside a session pod | `ompctl auth NAME PROVIDER` (anthropic·gcloud·aws·aws-configure·az·gh) |
| Port-forward a session pod to localhost | `ompctl port-forward NAME LOCAL_PORT` |
| Transfer a local omp session onto a pod PVC | `./administrator.sh session-transfer NAME [LOCAL_DIR] [SESSION_ID]` |
| Onboard a team (idempotent) | `./administrator.sh team-add <team>` |
| List teams and bound groups | `./administrator.sh team-ls` |
| Remove a team | `./administrator.sh team-rm <team>` (prompts; warns if sessions exist) |

`terraform apply` is idempotent.

## Workflows

- **Stand up from scratch:**
  1. Create tfvars: `infra/terraform.tfvars` with `project`, `admin_gcp_account`, and optionally `omp_config_memory=true` / `omp_config_thinking=true`.
  2. `cd infra && terraform init -backend-config="bucket=<state-bucket>" && terraform apply`
  3. `./administrator.sh vault-add shared/gemini-api-key` (Gemini bootstrap key).
  4. Use the manager skill to create sessions.

- **Inspect:** `status` for cluster state + nodes + sessions; `credentials` to refresh
  kubectl context.

- **Add a credential:** run `vault-add ENTRY` — prompts interactively (hidden, never in history).
  Subtree conventions: `shared/<key>` for platform creds all sessions may use;
  `users/<name>/<key>` for personal creds scoped to one user.
  Path becomes env var: subtree prefix stripped, `/`/`-` → `_`, uppercased.
  `shared/ollama-cloud-api-key` → `OLLAMA_CLOUD_API_KEY`.
  End names with a secret keyword (`token`, `key`, `secret`, `password`) for auto-obfuscation.

- **The `mirantis-services` skill needs:**
  ```bash
  ./administrator.sh vault-add users/jnesbitt/atlassian-email   # prompts for value
  ./administrator.sh vault-add users/jnesbitt/atlassian-token
  ```

- **Onboard a team:** (1) Workspace admin creates `omp-team-<team>@<domain>`, nests it
  in `gke-security-groups@<domain>`, adds members; (2) `./administrator.sh team-add <team>`.
  Creates `omp-team-<team>` namespace + Role (sessions CRUD + secrets CRUD) +
  `clusterViewer` IAM (kubectl access) + `secretmanager.viewer` IAM (vault-ls).
  Team members add personal credentials to GSM via `ompctl cred add` and request them
  via `subtrees: ["users/<name>"]` in Session CRs — no admin involvement for rotation.
  `terraform apply` enables `--security-group` on the cluster (GKE Groups-for-RBAC) and
  adds the `omp-admins@<domain>` ClusterRoleBinding. Override the domain:
  `OMP_GROUP_DOMAIN=example.com ./administrator.sh team-add myteam`.
  See [access-control.md](skill://administrator/../../docs/access-control.md).

- **Personal credentials:** users add their own credentials to GSM via `ompctl cred add`
  and request them via `subtrees: ["users/<name>"]` in Session CRs. See `ompctl --help`.

- **Enable local-model features:** set `omp_config_memory = true` and/or `omp_config_thinking = true`
  in `infra/terraform.tfvars`, then `terraform apply`. Updates the Helm chart values;
  running pods pick up the new omp-config on next restart.

## Gemini API key (platform bootstrap)

The Gemini API key lets sessions start authenticated before any OAuth flow. Store it as a vault credential:

```bash
./administrator.sh vault-add shared/gemini-api-key   # prompts for value
```

Then add `"shared"` to `spec.subtrees` in session CRs. ESO syncs it into `omp-creds` in the session namespace; the env var `GEMINI_API_KEY` is auto-obfuscated.

## Per-session provider auth

Interactive logins (Anthropic, gcloud, AWS SSO, Azure) and a GitHub PAT are completed
**inside a session pod** — not cluster-wide — via `ompctl auth NAME PROVIDER`:

```bash
ompctl auth work anthropic       # device code — visit the URL in your browser
ompctl auth work gcloud          # device code → gcloud ADC on the PVC
ompctl auth work aws-configure   # one-time SSO profile wizard, then: ompctl auth work aws
ompctl auth work az              # device code
printf '%s' "$PAT" | ompctl auth work gh   # PAT on stdin (never argv)
```

Credentials land under `$HOME` on the session PVC and survive pod restarts. For
browser-redirect flows (e.g. `aws configure sso`) use
`ompctl port-forward NAME LOCAL_PORT`. These are session-scoped operations —
the full workflow (including the `spec.authBroker` sidecar for automatic token refresh)
lives in the `manager` skill. Cluster-wide static keys that every session needs (e.g. a
Gemini API key) go through `vault-add` (`shared/gemini-api-key`); per-user/per-session secrets go
through `vault-add` as well.

## Guardrails

- `destroy` is irreversible — prompts for `yes`; surface the warning to the user before
  running.
- Images come from GHCR CI; this role never builds or pushes images.
- Never echo a credential value — `vault-add` reads from stdin only.
- These scripts never push or open PRs; follow the repo git rules for any commits.

## ompctl (self-service and session CLI)

`ompctl` is a Python CLI for operations that are genuinely imperative (credentials,
session lifecycle, auth flows). It requires `GCP_PROJECT` to be set; vault/cred commands
that grant ESO access also need `OMP_ESO_SA`.
It runs via `uv` (the `#!/usr/bin/env -S uv run --script` shebang), which auto-installs its
Python deps (`kubernetes`, `google-cloud-secret-manager`) from inline PEP 723 metadata on first
run — no manual pip/venv. Requires `uv` on PATH (mise provides it) and a kubeconfig
(`gcloud container clusters get-credentials` / `./administrator.sh credentials`, which uses
`gke-gcloud-auth-plugin`). Admins without a kubeconfig can still add user credentials with
`./administrator.sh vault-add users/<name>/<key>` (gcloud-only).

### Credential management

| Command | Purpose |
| --- | --- |
| `ompctl cred add <key>` | Add a personal credential to GSM (`users/<you>/<key>`) — prompts for value |
| `ompctl cred ls` | List your personal credentials in GSM |
| `ompctl vault add <entry>` | Admin: add a `shared/` or `users/` credential to GSM |
| `ompctl vault ls [<subtree>]` | List vault entry names (never values) |

Example — add a personal Atlassian token:

```bash
GCP_PROJECT=tools-348616 ompctl cred add atlassian-token
# prompts: Enter value for users/jnesbitt/atlassian-token (hidden):
```

Then request it in a Session CR: `subtrees: ["users/jnesbitt"]`.

### Session lifecycle

| Command | Purpose |
| --- | --- |
| `ompctl session list` | List every session across all namespaces (phase, state, image, join status) |
| `ompctl session stop <name>` | Scale session StatefulSet to 0 replicas (PVC retained) |
| `ompctl session start <name>` | Resume a stopped session (scale to 1) |
| `ompctl session restart <name>` | Recreate the pod — re-pulls `:latest` (imagePullPolicy: Always); the normal way to pick up a newer omp build |
| `ompctl session link <name>` | Print current join/view links (tokens) from Session CR status |
| `ompctl session image <name> [<image>]` | Only needed if pinned: clear the pin (omit image) or pin to `<image>` |

### Auth and port-forward

| Command | Purpose |
| --- | --- |
| `ompctl auth <session> <provider>` | Interactive auth inside pod (providers: `anthropic` `gcloud` `aws` `aws-configure` `az` `gh`) |
| `ompctl port-forward <session> <port>` | Forward session pod port to localhost |

Example — gcloud ADC inside a running session:

```bash
GCP_PROJECT=tools-348616 ompctl auth work gcloud
# Opens device-code URL; token lands on the session PVC

GCP_PROJECT=tools-348616 ompctl port-forward work 8080
# Forwards pod port 8080 → localhost:8080 for browser-redirect OAuth flows
```

Required env vars: `GCP_PROJECT=<project-id>`. For vault/cred commands that configure
ESO access: `OMP_ESO_SA=<omp-eso-sa-email>`.
