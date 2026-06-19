---
name: administrator
description: Act as the administrator for the GKE cluster from this repo — provision the cluster + IAM, bootstrap the platform runtime (ESO, operator), check status, get credentials, destroy, configure the platform (setup/tune), and manage the credential vault (vault-add/vault-ls). Use when the user asks to create, stand up, bootstrap, check on, get credentials for, or tear down the GKE cluster; configure omp; or add/list credentials in the vault. For session lifecycle (new/login/attach/kill/collab) use the `manager` skill.
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
| Store a credential (value on **stdin**) | `printf '%s' "$VAL" \| ./administrator.sh vault-add services/github/token` |
| List vault entry NAMES (never values) | `./administrator.sh vault-ls [SUBTREE]` |

`provision`, `bootstrap`, `credentials`, and `setup` are idempotent.

## Workflows

- **Stand up from scratch:** `provision` → `bootstrap` (confirm `BOOTSTRAP_OK`) →
  `setup` (confirm `SETUP_OK`) → add credentials with `vault-add` → use the
  manager skill to create sessions.

- **Inspect:** `status` for cluster state + nodes + sessions; `credentials` to refresh
  kubectl context.

- **Add a credential:** pipe the value on stdin — never as an argument.
  Entry path becomes env var name (`/` and `-` → `_`, uppercased, subtree prefix stripped):
  `services/github/token` → `GITHUB_TOKEN`. End entry names with a secret keyword
  (`token`, `key`, `secret`, `password`) so obfuscation fires.

- **The `mirantis-services` skill needs:**
  ```bash
  printf '%s' '<email>' | ./administrator.sh vault-add services/atlassian/email
  printf '%s' '<token>' | ./administrator.sh vault-add services/atlassian/token
  ```

- **Enable local-model features:** `tune --memory` and/or `--thinking`; no flag = both.
  Patches the omp-config ConfigMap; running pods pick it up on next restart.

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

## Guardrails

- `destroy` is irreversible — prompts for `yes`; surface the warning to the user before
  running.
- Images come from GHCR CI; this role never builds or pushes images.
- Never echo a credential value — `vault-add` reads from stdin only.
- These scripts never push or open PRs; follow the repo git rules for any commits.
