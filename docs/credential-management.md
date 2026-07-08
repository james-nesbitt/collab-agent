# Credential Management

How secrets flow into omp sessions, how to scope them per-operator,
and how to wire up specific services.

---

## Architecture

Two injection layers, applied in order (later wins for the same key):

```
                                            ┌─→ pod envFrom            (omp process: model-provider keys)
GSM vault ─→ ESO ─→ omp-creds (K8s Secret) ─┤
                                            └─→ /etc/omp-creds/ files  (agent tools: read via $(cat …))

Session CR spec.env ─────────────────────────→ pod env []
```

**Session tools read credentials from the `/etc/omp-creds/` files, not env vars** — some
omp builds scrub credential env from tool subprocesses, so files are the version-independent
path. See the `credential-access` skill. (omp's own model-provider keys still come via envFrom.)

| Layer | Scope | Managed by | Rotation |
|---|---|---|---|
| `omp-creds` | per-session, per-subtree | GSM + ESO | ESO re-syncs hourly (or force-sync); files auto-refresh ~1 min, env vars on pod restart |
| `spec.env` | single session | Session CR | patch CR; restart pod |

Credentials live in GSM subtrees. The platform ships with two subtrees:
- `shared/` — platform-wide keys managed by the admin (e.g. `shared/gemini-api-key`)
- `users/<username>/` — personal keys added by each user via `ompctl cred add`

A session requests its subtrees in `spec.subtrees`:
```yaml
spec:
  subtrees: ["shared", "users/jnesbitt"]
```
ESO builds one K8s Secret (`omp-creds`) per session from all matched GSM secrets.

Global obfuscation (`secrets.enabled: true` in omp-config) replaces every matched
env-var value with `#XXXX#` before text reaches the model. Variables whose names
contain `TOKEN`, `KEY`, `SECRET`, or `PASSWORD` are matched automatically; others
need a value-shape regex in `platform/secrets.yml`.

---

## Personal credential self-service

Each user manages their own credentials in GSM under `users/<username>/`.
No admin involvement after initial cluster onboarding — users add and rotate
their own secrets independently.

### Adding personal credentials

**Prerequisites:** `ompctl` runs via `uv` (its `uv run --script` shebang auto-installs the
`kubernetes` + `google-cloud-secret-manager` deps from inline PEP 723 metadata on first run —
no manual pip). Needs `uv` on PATH and a kubeconfig (`gcloud container clusters get-credentials`,
which authenticates via `gke-gcloud-auth-plugin`). Admins without a kubeconfig can use
`./administrator.sh vault-add users/<name>/<key>` instead (gcloud-only).

```bash
# Add an Atlassian API token (prompted hidden)
GCP_PROJECT=<project-id> OMP_ESO_SA=omp-eso@<project-id>.iam.gserviceaccount.com \
  ./ompctl cred add atlassian-token

# Add a GitHub token
GCP_PROJECT=<project-id> OMP_ESO_SA=omp-eso@<project-id>.iam.gserviceaccount.com \
  ./ompctl cred add github-token

# List your credentials
GCP_PROJECT=<project-id> ./ompctl cred ls
```

Or set the env vars once in your shell profile:
```bash
export GCP_PROJECT=<project-id>
export OMP_ESO_SA=omp-eso@<project-id>.iam.gserviceaccount.com
./ompctl cred add atlassian-token
```

### Referencing in a Session CR

```yaml
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: jnesbitt-work
  namespace: omp-system
spec:
  subtrees:
    - shared         # platform-wide keys (GEMINI_API_KEY etc.)
    - users/jnesbitt # personal keys (ATLASSIAN_TOKEN, GITHUB_TOKEN etc.)
```

The env var name is derived from the key: `atlassian-token` → `ATLASSIAN_TOKEN`,
`github-token` → `GITHUB_TOKEN`.

**Rotation:** run `ompctl cred add <same-key>` again — a new GSM version is added.
ESO picks it up within 1 hour (or restart the pod to apply immediately).

### Ownership enforcement

A ValidatingAdmissionPolicy prevents any user from referencing another user's
`users/<name>/` subtree in their Session CR. Platform admins and the operator SA
are exempt.

---

## Session CR spec.env overrides

Operator-specific credentials can be injected directly into the Session CR's
`spec.env`. Values are stored in the CR itself (RBAC-governed in its namespace).

```yaml
spec:
  subtrees: ["shared"]
  env:
    EXTRA_FLAG: "true"
```

For sensitive inline values prefer `spec.env` only for non-secret config. Use
GSM subtrees for anything that needs rotation, audit history, or cross-session
sharing.

---

## Service-specific wiring

### JIRA and Confluence

| Env var | Source | vault entry |
|---|---|---|
| `ATLASSIAN_EMAIL` | GSM `users/<name>/atlassian-email` | `ompctl cred add atlassian-email` |
| `ATLASSIAN_TOKEN` | GSM `users/<name>/atlassian-token` | `ompctl cred add atlassian-token` |

```bash
ompctl cred add atlassian-token
ompctl cred add atlassian-email
```

Add `users/<your-username>` to `spec.subtrees` in the Session CR. See the
`mirantis-services` skill for usage patterns. `ATLASSIAN_TOKEN` auto-obfuscates
(`TOKEN` suffix); `ATLASSIAN_EMAIL` does not (add a regex to `platform/secrets.yml`
if the value shape needs masking).

---

### GitHub — CLI and API

| Env var | Used by | Notes |
|---|---|---|
| `GITHUB_TOKEN` | `gh` CLI, `curl` API calls | auto-obfuscated |
| `GH_TOKEN` | `gh` CLI (alternative) | use one, not both |

```bash
ompctl cred add github-token   # prompted hidden; stores under users/<you>/github-token
```

Add `users/<your-username>` to `spec.subtrees` in the Session CR.

Session **tools** read credentials from files under `/etc/omp-creds/` (see the
`credential-access` skill). Reference the file inline — for `gh` and for raw API calls:

```bash
# gh CLI (feed the token from the file for this command)
GH_TOKEN="$(cat /etc/omp-creds/GITHUB_TOKEN)" gh api user
# raw API
curl -fsS -H "Authorization: Bearer $(cat /etc/omp-creds/GITHUB_TOKEN)" https://api.github.com/user
```

**SSH-based git:** SSH keys are not env vars. Place the private key in `~/.ssh/`
on the pod (it persists on the PVC across restarts). Either copy it in at session
creation via `kubectl cp`, or store the key value in GSM and write it to disk in
the session entrypoint (not currently automated — requires a custom entrypoint
extension or a post-session `kubectl exec` step).

**HTTPS-based git:** git reads `GITHUB_TOKEN` via a credential helper. Add to the
session's git config (once, persists on PVC):

```bash
git config --global credential.helper \
  '!f() { echo "username=x-access-token"; echo "password=$(cat /etc/omp-creds/GITHUB_TOKEN)"; }; f'
```

---

### GCP (`gcloud`)

| Auth method | When to use |
|---|---|
| Workload Identity (automatic) | session pod SA has GCP IAM bindings — no key needed |
| `GOOGLE_APPLICATION_CREDENTIALS` | service account JSON key file on disk |
| Interactive `gcloud auth login` | human operator doing one-off work; token persists on PVC |

Workload Identity is blocked for session pods by the NetworkPolicy (metadata server
`169.254.169.254` is denied) — intentional, to prevent credential escalation. Use
a service account key file instead:

```bash
# Store the JSON key in GSM
printf '%s' "$(cat sa-key.json)" | ./administrator.sh vault-add shared/gcp/sa-key

# In the session: GOOGLE_APPLICATION_CREDENTIALS must point to a file, not an env var value.
# Write it to disk (once, persists on PVC):
printf '%s' "$GCP_SA_KEY" > ~/.config/gcloud/sa-key.json
export GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/sa-key.json
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
```

`GCP_SA_KEY` will need a value-shape regex in `platform/secrets.yml` to trigger
obfuscation (JSON content does not match the default keyword patterns).

---

### AWS CLI

| Env var | vault entry | Notes |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | `shared/aws/access-key-id` | auto-obfuscated (`KEY` suffix) |
| `AWS_SECRET_ACCESS_KEY` | `shared/aws/secret-access-key` | auto-obfuscated (`KEY` suffix) |
| `AWS_SESSION_TOKEN` | runtime injection (Approach C) | short-lived; rotate via runtime patch |
| `AWS_DEFAULT_REGION` | `shared/aws/default-region` | not sensitive; safe to set via `spec.env` |

```bash
printf '%s' "$AWS_KEY_ID"     | ./administrator.sh vault-add shared/aws/access-key-id
printf '%s' "$AWS_SECRET_KEY" | ./administrator.sh vault-add shared/aws/secret-access-key
```

The AWS CLI and SDKs pick up all three vars automatically. For assumed-role /
STS sessions, `AWS_SESSION_TOKEN` is short-lived — use Approach C (runtime Secret
patch) to rotate it without killing the session.

---

### Azure CLI

| Auth method | Env vars | Notes |
|---|---|---|
| Service principal | `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` | fully automated |
| Interactive device code | — | `az login`; token persists on PVC |

```bash
printf '%s' "$CLIENT_ID"     | ./administrator.sh vault-add shared/azure/client-id
printf '%s' "$CLIENT_SECRET" | ./administrator.sh vault-add shared/azure/client-secret
printf '%s' "$TENANT_ID"     | ./administrator.sh vault-add shared/azure/tenant-id
```

With all three vars injected, `az login --service-principal` is implicit — the
Azure CLI detects the env vars automatically. `AZURE_CLIENT_SECRET` auto-obfuscates
(`SECRET` suffix); `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` do not (add regexes to
`platform/secrets.yml` if needed).

For interactive login: `az login` opens a device-code flow. The resulting token is
cached in `~/.azure/` on the PVC and survives pod restarts. This is the simplest
path for human operators doing one-off work.

---

## Rotation and revocation

| Scenario | Action |
|---|---|
| Rotate a GSM vault entry | `./administrator.sh vault-add <same-entry>` (new version); ESO picks up within 1 h, or restart pod immediately |
| Revoke a session's access | `kubectl delete session NAME -n omp-system` — namespace + PVC + all secrets GC'd |
| Revoke a single credential from a running session | delete the GSM secret version; wait for ESO refresh or restart pod |
| Rotate the Gemini platform key | `./administrator.sh vault-add shared/gemini-api-key` (new version added to GSM); ESO picks up within 1 h or restart pods |
| Emergency: revoke all session credentials | `kubectl delete sessions --all -n omp-system` — all session namespaces and their Secrets are GC'd by the operator |

---

## Obfuscation reference

Variables are obfuscated (`#XXXX#` to the model) if their name contains one of
these substrings (case-insensitive): `TOKEN`, `KEY`, `SECRET`, `PASSWORD`.

For variables that don't match (e.g. `ATLASSIAN_EMAIL`, `AZURE_TENANT_ID`,
`GCP_PROJECT`), add a value-shape regex to `platform/secrets.yml` and re-run
`terraform apply` (from `infra/`) to rebuild the omp-config ConfigMap.
