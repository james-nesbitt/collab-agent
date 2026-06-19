# Credential Management

How secrets flow into omp sessions, how to scope them per-operator,
and how to wire up specific services.

---

## Architecture

Three injection layers, applied in order (last wins for the same key):

```
GSM vault  ──→  ESO  ──→  omp-creds (per-session K8s Secret)  ──→  pod envFrom
                                                                         ↑
omp-bootstrap-env (omp-system K8s Secret, copied to session ns)  ──→  pod envFrom
                                                                         ↑
Session CR spec.env  ──────────────────────────────────────────→  pod env []
```

| Layer | Scope | Managed by | Rotation |
|---|---|---|---|
| `omp-creds` | per-session, per-subtree | GSM + ESO | ESO re-syncs hourly; immediate on session restart |
| `omp-bootstrap-env` | all sessions | kubectl (omp-system) | patch secret; restart session pod |
| `spec.env` | single session | Session CR | patch CR; restart pod |

Global obfuscation (`secrets.enabled: true` in omp-config) replaces every matched
env-var value with `#XXXX#` before text reaches the model. Variables whose names
contain `TOKEN`, `KEY`, `SECRET`, or `PASSWORD` are matched automatically; others
need a value-shape regex in `platform/secrets.yml`.

---

## Multi-operator credential injection

Three viable approaches for sessions shared across operators with different
credential identities.

### Approach A — Named subtrees per operator (recommended)

Each operator owns a subtree in GSM. Sessions are created with the relevant
subtrees requested. Credentials are scoped at provisioning time; a session never
sees another operator's subtree.

```bash
# Administrator: add Alice's GitHub token under her subtree
printf '%s' "$ALICE_TOKEN" | ./administrator.sh vault-add operators/alice/github/token

# Manager: launch a session for Alice with her subtree
kubectl apply -f - <<EOF
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: alice-work
  namespace: omp-system
spec:
  subtrees: ["services", "operators/alice"]
  view: false
EOF
```

Alice's session gets `GITHUB_TOKEN` from her subtree; she never sees Bob's entry.

**Post-session rotation:** `./administrator.sh vault-add operators/alice/github/token`
(new version in GSM). ESO re-syncs within the hour. For immediate pickup: restart
the pod (`kubectl delete pod omp -n omp-session-alice-work`).

**Tradeoffs:** clean GSM audit trail, IAM-governed, per-secret ESO `secretAccessor`
binding (added by `vault-add`). Requires a session per operator. No runtime
credential swap without a pod restart.

---

### Approach B — Session CR spec.env overrides

Operator-specific credentials are injected directly into the Session CR's
`spec.env`. No GSM entry needed; values are stored in the CR itself (which lives
in `omp-system` and is RBAC-governed).

```yaml
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: alice-work
  namespace: omp-system
spec:
  subtrees: ["services"]
  view: false
  env:
    - name: GITHUB_TOKEN
      value: "ghp_alice_token_here"   # never do this for long-lived secrets
    - name: AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: alice-aws-creds       # K8s Secret in omp-system
          key: access-key-id
```

Using `valueFrom.secretKeyRef` (referencing a K8s Secret in `omp-system`) is
preferable to inline `value` for anything sensitive — the value is not stored in
the CR itself.

**Post-session credential update:** create/patch the referenced Secret, then
restart the pod. The operator will re-read `spec.env` on the next pod start.

**Tradeoffs:** fast to set up, no GSM required, per-session override is precise.
Inline values appear in `kubectl get session -o yaml`; always use `secretKeyRef`
for real secrets. K8s Secrets in omp-system are governed by cluster RBAC, not GSM
IAM — no rotation audit trail.

---

### Approach C — Runtime Secret patch in session namespace

For credentials that must change after a session is already running (e.g.,
short-lived STS tokens, rotated keys mid-session), write a new K8s Secret directly
into the session namespace and restart the pod.

```bash
SESSION=alice-work
NS="omp-session-${SESSION}"

# Create or replace a credential in the session namespace
kubectl create secret generic session-runtime-creds \
  -n "${NS}" \
  --from-literal=AWS_SESSION_TOKEN="$(cat)" \   # value on stdin
  --dry-run=client -o yaml | kubectl apply -f -

# Patch the pod to mount it (if not already in envFrom), then restart
kubectl delete pod omp -n "${NS}"
# operator restartPolicy:Always brings it back with new creds loaded
```

To add `session-runtime-creds` to the pod's `envFrom` without modifying the
operator: the operator already includes `omp-creds` and `omp-bootstrap-env` via
`envFrom optional=True`. A third optional Secret can be added by patching the
operator's pod spec template or by adding it to the Session CR via `spec.env`
`valueFrom.secretKeyRef`.

**Post-session update:** overwrite the Secret (same `kubectl apply` pattern) then
restart the pod. The new values load on the next pod start.

**Tradeoffs:** immediate, no GSM or ESO dependency. The Secret lives only in the
session namespace; deleted when the Session CR is deleted. Not appropriate for
shared platform credentials — use the bootstrap env for those.

---

## Service-specific wiring

### JIRA and Confluence

| Env var | Source | vault entry |
|---|---|---|
| `ATLASSIAN_EMAIL` | GSM `services` subtree | `services/atlassian/email` |
| `ATLASSIAN_TOKEN` | GSM `services` subtree | `services/atlassian/token` |

```bash
printf '%s' "$EMAIL" | ./administrator.sh vault-add services/atlassian/email
printf '%s' "$TOKEN" | ./administrator.sh vault-add services/atlassian/token
```

Sessions launched with `subtrees: ["services"]` inject both vars. See the
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
printf '%s' "$GITHUB_TOKEN" | ./administrator.sh vault-add services/github/token
```

The `gh` CLI picks up `GITHUB_TOKEN` or `GH_TOKEN` automatically — no `gh auth
login` needed. For API calls use it inline:

```bash
curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user
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
  '!f() { echo "username=x-access-token"; echo "password=$GITHUB_TOKEN"; }; f'
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
printf '%s' "$(cat sa-key.json)" | ./administrator.sh vault-add services/gcp/sa-key

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
| `AWS_ACCESS_KEY_ID` | `services/aws/access-key-id` | auto-obfuscated (`KEY` suffix) |
| `AWS_SECRET_ACCESS_KEY` | `services/aws/secret-access-key` | auto-obfuscated (`KEY` suffix) |
| `AWS_SESSION_TOKEN` | runtime injection (Approach C) | short-lived; rotate via runtime patch |
| `AWS_DEFAULT_REGION` | `services/aws/default-region` | not sensitive; safe to put in bootstrap-env |

```bash
printf '%s' "$AWS_KEY_ID"     | ./administrator.sh vault-add services/aws/access-key-id
printf '%s' "$AWS_SECRET_KEY" | ./administrator.sh vault-add services/aws/secret-access-key
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
printf '%s' "$CLIENT_ID"     | ./administrator.sh vault-add services/azure/client-id
printf '%s' "$CLIENT_SECRET" | ./administrator.sh vault-add services/azure/client-secret
printf '%s' "$TENANT_ID"     | ./administrator.sh vault-add services/azure/tenant-id
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
| Rotate the Gemini platform key | `kubectl create secret generic omp-bootstrap-env -n omp-system --from-literal=GEMINI_API_KEY=<new> --dry-run=client -o yaml \| kubectl apply -f -`; restart running session pods |
| Emergency: revoke all session credentials | `kubectl delete sessions --all -n omp-system` — all session namespaces and their Secrets are GC'd by the operator |

---

## Obfuscation reference

Variables are obfuscated (`#XXXX#` to the model) if their name contains one of
these substrings (case-insensitive): `TOKEN`, `KEY`, `SECRET`, `PASSWORD`.

For variables that don't match (e.g. `ATLASSIAN_EMAIL`, `AZURE_TENANT_ID`,
`GCP_PROJECT`), add a value-shape regex to `platform/secrets.yml` and re-run
`./administrator.sh setup` to rebuild the ConfigMap.
