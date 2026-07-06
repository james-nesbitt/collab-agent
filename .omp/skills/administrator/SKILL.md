---
name: administrator
description: Act as the administrator for the GKE cluster from this repo — provision the cluster + IAM, bootstrap the platform runtime (ESO, operator), check status, get credentials, destroy, configure the platform (setup/tune), manage the credential vault (vault-add/vault-ls), and onboard/manage teams (team-add/team-ls/team-rm). Use when the user asks to create, stand up, bootstrap, check on, get credentials for, or tear down the GKE cluster; configure omp; add/list credentials in the vault; or add/list/remove a team. For session lifecycle (new/login/attach/kill/collab) use the `manager` skill.
---

# Administrator

You drive the **GKE cluster lifecycle, platform config, and credential vault** via
`./administrator.sh`, run from the repo root. Session lifecycle (applying CRs, attaching,
getting collab links) is the [`manager`](skill://manager) skill.

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
| Apply ClusterSecretStore + omp-config ConfigMap | `./administrator.sh setup` |
| Tune local-model features (mnemopi, auto thinking) | `./administrator.sh tune [--memory] [--thinking]` (no flag = both) |
| Store a credential | `./administrator.sh vault-add shared/ollama-cloud-api-key` (prompts interactively) |
| List vault entry NAMES (never values) | `./administrator.sh vault-ls [SUBTREE]` |
| Auth a provider inside a session pod | `./administrator.sh auth NAME PROVIDER` (anthropic·gcloud·aws·aws-configure·az·gh) |
| Port-forward a session pod to localhost | `./administrator.sh port-forward NAME LOCAL_PORT` |
| Transfer a local omp session onto a pod PVC | `./administrator.sh session-transfer NAME [LOCAL_DIR] [SESSION_ID]` |
| Onboard a team (idempotent) | `./administrator.sh team-add <team>` |
| List teams and bound groups | `./administrator.sh team-ls` |
| Remove a team | `./administrator.sh team-rm <team>` (prompts; warns if sessions exist) |
| Onboard a user (personal cred namespace) | `./administrator.sh user-add <name>` |
| Remove a user | `./administrator.sh user-rm <name>` (prompts) |
| Add/update a personal K8s Secret (hidden prompts) | `./administrator.sh user-cred-add <secret> <KEY> [<KEY2>...] [--user <name>]` |
| List personal K8s Secret names + keys | `./administrator.sh user-cred-ls [--user <name>]` |

`provision`, `bootstrap`, `credentials`, and `setup` are idempotent.

## Workflows

- **Stand up from scratch:** `provision` → `bootstrap` (confirm `BOOTSTRAP_OK`) →
  `setup` (confirm `SETUP_OK`) → add credentials with `vault-add` → use the
  manager skill to create sessions.

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
  Team members self-manage personal credential Secrets in their namespace and reference
  them via `spec.credentialSecrets` in Session CRs — no admin involvement for rotation.
  `provision` enables `--security-group` on the cluster (GKE Groups-for-RBAC);
  `bootstrap` adds `omp-admins@<domain>` ClusterRoleBinding. Override the domain:
  `OMP_GROUP_DOMAIN=example.com ./administrator.sh team-add myteam`.
  See [access-control.md](skill://administrator/../../docs/access-control.md).

- **Onboard a user (personal creds):** `user-add <name>` creates `omp-user-<name>`, grants
  that user secrets CRUD in that namespace and `secretmanager.viewer` IAM (vault-ls).
  Users then self-manage K8s Secrets with `user-cred-add` and reference them in Session CRs
  as `credentialSecrets: ["<name>/<secret>"]`. Values are prompted hidden, base64-encoded
  in Python, and piped to `kubectl apply` — never appear in process args or shell history.
  `github-user-cred [<name>]` creates the `github-token` secret from `gh auth token`.
  `user-rm <name>` removes the namespace and IAM binding.

- **Enable local-model features:** `tune --memory` and/or `--thinking`; no flag = both.
  Patches the omp-config ConfigMap; running pods pick it up on next restart.
  Tiny-model weights (`lfm2-350m` ~212 MB, `qwen3-1.7b` ~1.1 GB) are baked into the
  session image and seeded to the session PVC on first pod start — no downloads at runtime.
  `setup` updates the master ConfigMap in `omp-system` only; running session pods keep
  their stale copy until you manually patch their session-namespace ConfigMap and restart.

## Platform-wide environment injection (omp-bootstrap-env)

`omp-bootstrap-env` is a K8s Secret in `omp-system` that the operator copies into
every session namespace at creation time. All key-value pairs become env vars in every
session pod — injected after `omp-creds` (GSM vault) so GSM values take precedence.

Use this for platform-level API keys that all sessions need, where the full GSM→ESO
pipeline is overkill. **This is a workaround** — prefer `vault-add` for per-user or
per-session credentials. The secret is stored as a plain K8s Secret with no rotation
audit trail.

**Inject a Gemini API key** so sessions start authenticated without `omp auth login`:

```bash
# Create (first time)
kubectl create secret generic omp-bootstrap-env \
  -n omp-system \
  --from-literal=GEMINI_API_KEY=<your-key>

# Update an existing secret
kubectl create secret generic omp-bootstrap-env \
  -n omp-system \
  --from-literal=GEMINI_API_KEY=<new-key> \
  --dry-run=client -o yaml | kubectl apply -f -
```

`GEMINI_API_KEY` matches the auto-obfuscation pattern (`KEY` suffix) — the model
receives `#XXXX#`, never the raw value. Already-running sessions are unaffected;
new sessions created after the secret exists pick it up automatically.

## Per-session provider auth

Interactive logins (Anthropic, gcloud, AWS SSO, Azure) and a GitHub PAT are completed
**inside a session pod** — not cluster-wide — via `./administrator.sh auth NAME PROVIDER`:

```bash
./administrator.sh auth work anthropic       # device code — visit the URL in your browser
./administrator.sh auth work gcloud          # device code → gcloud ADC on the PVC
./administrator.sh auth work aws-configure   # one-time SSO profile wizard, then: auth work aws
./administrator.sh auth work az              # device code
printf '%s' "$PAT" | ./administrator.sh auth work gh   # PAT on stdin (never argv)
```

Credentials land under `$HOME` on the session PVC and survive pod restarts. For
browser-redirect flows (e.g. `aws configure sso`) use
`./administrator.sh port-forward NAME LOCAL_PORT`. These are session-scoped operations —
the full workflow (including the `spec.authBroker` sidecar for automatic token refresh)
lives in the `manager` skill. Cluster-wide static keys that every session needs (e.g. a
Gemini API key) go through `omp-bootstrap-env` above; per-user/per-session secrets go
through `vault-add`.

## Guardrails

- `destroy` is irreversible — prompts for `yes`; surface the warning to the user before
  running.
- Images come from GHCR CI; this role never builds or pushes images.
- Never echo a credential value — `vault-add` reads from stdin only.
- These scripts never push or open PRs; follow the repo git rules for any commits.
