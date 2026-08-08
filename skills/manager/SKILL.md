---
name: manager
description: Act as the manager for the GKE cluster from this repo — run sessions (create with injected credentials via Session CR, login, attach, list, kill, share a collab join link) directly with kubectl. Use when the user asks to start, share, attach, login, list, or kill a session, or get a collab link. For cluster provisioning/bootstrap/destroy, platform config (setup/tune), or credential vault (vault-add/vault-ls) use the `administrator` skill.
---

# Manager

You manage sessions on the cluster directly with `kubectl`. There is no manager
script. Platform config and vault operations are handled by `./administrator.sh`
— see the [`administrator`](skill://administrator) skill.

Full reference: read `docs/roles/manager.md`. Collab routes through our self-hosted
relay by default (not `my.omp.sh`) — see [`docs/relay.md`](../../docs/relay.md) for
how it works and join-failure troubleshooting. To drive a session directly via
`kubectl exec` + tmux instead of collab (e.g. farming out a long task without
holding a connection open), see
[`docs/farm-out-execution.md`](../../docs/farm-out-execution.md).

## Prerequisites

kubectl configured for the cluster. Check with:
```bash
kubectl config current-context  # should be gke_<project>_<zone>_omp-cluster
```
Or refresh: `./administrator.sh credentials`.

Session CRs live in `omp-system` (admin) or `omp-team-<team>` (team sessions). Session pods
run in `omp-session-<name>` (admin) or `omp-session-<team>-<name>` (team).

## Create a session

```bash
kubectl apply -f - <<EOF
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: work
  namespace: omp-system
spec:
  subtrees: ["shared"]
  view: false
EOF
```

List more entries in `spec.subtrees` as needed, e.g. `["shared", "users/asmith"]`.
`asmith` here is a stand-in — the real value is the operator's gcloud account's
username (`gcloud config get-value account`, part before `@`); see
[credential-management.md](../../docs/credential-management.md#personal-credential-self-service)
for the exact resolution. Session CRs are hand-written YAML with no auto-scoping —
unlike `ompctl cred add`, nothing derives this for you.

Wait for the session to reach `Hosting`:
```bash
kubectl wait --for=jsonpath='{.status.phase}'=Hosting \
  session/work -n omp-system --timeout=180s
```


**Team session** (requires `team-add <team>` by admin first):
```yaml
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: my-session
  namespace: omp-team-<team>     # must match spec.team; CR is isolated to your namespace
spec:
  subtrees: ["shared", "users/asmith"]  # platform creds + personal GSM entries
  team: <team>
```
_Personal credentials are managed via `ompctl cred add` — see `ompctl --help`._
List available vault credential names (never values):
```bash
./administrator.sh vault-ls shared           # platform creds
./administrator.sh vault-ls users/asmith   # your personal entries
```
The join link is NOT in `kubectl get sessions` output. Retrieve explicitly:
```bash
kubectl get session my-session -n omp-team-<team> -o jsonpath='{.status.joinLink}'
```
## Command map

| Intent | Command |
| --- | --- |
| List all sessions (phase/state/namespace) | `kubectl get sessions -n omp-system` (or `-A` for every namespace) |
| List all sessions with image + join status | `ompctl session list` |
| Session status / phase | `kubectl get session NAME -n omp-system -o jsonpath='{.status.phase}'` |
| Kill session (destroys namespace + PVC) | `kubectl delete session NAME -n omp-system` |
| Stop session (keep PVC + namespace) | `ompctl session stop NAME` |
| Start a stopped session | `ompctl session start NAME` |
| Restart — recreate pod, re-pulls latest `:latest` image (imagePullPolicy: Always) | `ompctl session restart NAME` |
| Session was pinned to a specific image? Clear the pin (resume tracking latest) | `ompctl session image NAME` |
| Pin to a specific image (freeze during rollback/incident) | `ompctl session image NAME ghcr.io/james-nesbitt/collab-agent/omp-session:sha-XXXX` |
| Get collab join link/token | `ompctl session link NAME` (or `kubectl get session NAME -n omp-system -o jsonpath='{.status.joinLink}'`) |
| Auth a provider in a session | `ompctl auth NAME PROVIDER` — providers: `anthropic` `gcloud` `aws` `az` `gh` |
| Port-forward for browser OAuth | `ompctl port-forward NAME LOCAL_PORT` |
| Transfer local session to GKE pod | `./administrator.sh session-transfer NAME [LOCAL_DIR] [SESSION_ID]` |
| Skip setup wizard in tmux | `kubectl exec -n omp-session-NAME omp-0 -- bash -lc 'tmux send-keys -t omp Escape Escape Escape'` |
| Attach to session tmux | `kubectl exec -it -n omp-session-NAME omp-0 -- tmux attach -t omp` |
| Get view-only link | `kubectl get session NAME -n omp-system -o jsonpath='{.status.viewLink}'` |
| Trigger link re-capture | `kubectl annotate session NAME -n omp-system omp.mirantis.io/recapture=$(date +%s) --overwrite` |
| Inspect session events | `kubectl describe session NAME -n omp-system` |
| Check pod logs | `kubectl logs -n omp-session-NAME omp-0` |
| Check operator logs | `kubectl logs -n omp-system deploy/omp-operator` |

## Workflows

- **Launch and share (Gemini — zero-touch):**
  1. Apply Session CR; wait for `Hosting`.
  2. `kubectl get session work -n omp-system -o jsonpath='{.status.joinLink}'`
  3. Hand `omp join "<link>"` to operators.

- **Launch and share (Anthropic — device code):**
  1. Apply Session CR; wait for `Running`.
  2. Authenticate Anthropic (device code — visit URL in your browser):
     ```bash
     ompctl auth work anthropic
     ```
     Token saves to PVC; survives restarts. One-time per session.
  3. Dismiss setup wizard if omp is waiting:
     ```bash
     kubectl exec -n omp-session-work omp-0 -- bash -lc 'tmux send-keys -t omp Escape Escape Escape'
     ```
  4. Trigger collab link capture and hand to operators.

- **Authenticate a cloud CLI (gcloud / aws / az):**
  ```bash
  ompctl auth work gcloud      # device code → gcloud ADC on PVC
  ompctl auth work aws         # device code SSO login (profile must exist)
  ompctl auth work aws-configure  # interactive SSO wizard (browser redirect)
  ompctl auth work az          # device code → Azure token on PVC
  ```
  Credentials are stored under `$HOME` on the session PVC and survive pod restarts.
  Re-auth only needed when the token expires (gcloud/az: never for refresh; aws SSO: per portal policy ~8–12 h).

- **Authenticate GitHub (paste token):**
  ```bash
  printf '%s' "$MY_PAT" | ompctl auth work gh
  ```
  _Personal credentials are managed via `ompctl cred add` — see `ompctl --help`._

- **If the browser-redirect OAuth can't reach the pod** (`aws configure sso`; **not**
  `ompctl auth NAME anthropic`, which now manages this automatically — its
  callback port is fixed and pre-forwarded for you):
  ```bash
  # Terminal 1 — start the pod-side wizard FIRST; wait for it to print
  # "Open this URL in your browser" before starting the tunnel. `ompctl
  # port-forward` retries automatically if a connection races the pod-side
  # port before it's listening, but starting the wizard first avoids the race
  # altogether.
  kubectl exec -it -n omp-session-work omp-0 -- bash -lc \
    'aws configure sso --redirect-url http://localhost:8400/callback'
  # Terminal 2 — once Terminal 1 is waiting on the browser
  ompctl port-forward work 8400
  ```

- **Transfer a local omp session to a GKE pod:**
  ```bash
  # Most recent session for ~/prodeng-3468 → pod named prodeng-3468
  ./administrator.sh session-transfer prodeng-3468 ~/prodeng-3468

  # Specific session by ID prefix
  ./administrator.sh session-transfer prodeng-3468 ~/prodeng-3468 019f030d

  # From a deeper path (auto-injects RESUME_SESSION_ID for cross-path resume)
  ./administrator.sh session-transfer prodeng-3468 ~/Documents/Mirantis/research/prodeng-3468
  ```
  The session `.jsonl` is copied to the pod PVC via `kubectl cp`. The pod restarts and
  omp resumes the conversation. After the first resume, clear `RESUME_SESSION_ID` if set:
  ```bash
  kubectl patch session NAME -n omp-system --type=merge -p '{"spec":{"env":{"RESUME_SESSION_ID":null}}}'
  ```

- **If collab link is empty** (pod just restarted or auth just completed): trigger
  re-capture, wait ~15 s, then re-read `status.joinLink`. The operator sends `/collab`
  to the tmux pane — omp must be at the chat prompt (not in the setup wizard) for this
  to succeed.

- **Check what auth is active:**
  ```bash
  kubectl exec -n omp-session-NAME omp-0 -- bash -lc '
    echo "GEMINI_API_KEY set: $([ -n "$GEMINI_API_KEY" ] && echo yes || echo no)"
    echo "ANTHROPIC_OAUTH_TOKEN set: $([ -n "$ANTHROPIC_OAUTH_TOKEN" ] && echo yes || echo no)"
    echo "ANTHROPIC_REFRESH_TOKEN set: $([ -n "$ANTHROPIC_REFRESH_TOKEN" ] && echo yes || echo no)"
  '
  ```

## Troubleshooting

- **Session stuck in Pending/Provisioning:** `kubectl describe session NAME -n omp-system`
  — check operator logs for ExternalSecret or pod errors.
- **ExternalSecret not Valid:** GSM labels mismatch or ClusterSecretStore not ready —
  re-run `terraform apply` (from `infra/`) or manually apply `k8s/clustersecretstore.yaml`.
- **Pod stuck / image pull error:** `kubectl describe pod omp-0 -n omp-session-NAME` —
  check image tag and GHCR package visibility (must be public for anonymous pull).
- **A var is missing / subtree exported nothing.** Check GSM labels:
  `./administrator.sh vault-ls shared` (or `vault-ls users/<name>`). An empty subtree → session launches without
  those creds.

## Session lifecycle notes

- **Stop** (`state: stopped`) removes the pod only — namespace, PVC, secrets, and
  NetworkPolicies are retained. The conversation is preserved on the PVC.
- **Start** (`state: running`) recreates the pod and resumes the omp session via `-c`.
- **Restart** (`ompctl session restart NAME`, bumps `restartedAt` only) recreates the
  pod. Session pods run with `imagePullPolicy: Always`, and day to day `spec.image`
  is unset (tracking the operator's default `:latest` tag) — so a plain restart is
  the normal way to pick up a newer omp build; it re-pulls whatever `spec.image`
  currently resolves to.
- **Pin / unpin an image** (`ompctl session image NAME [<image>]`) only matters once
  a session has been explicitly pinned via `spec.image` (e.g. to freeze a version
  during an incident). Pass `<image>` to pin; omit it to clear the pin and go back
  to tracking latest. Either way it bumps `restartedAt` too, recreating the pod
  immediately.
- `kubectl delete session` is the **only** operation that destroys the PVC.
- After restart/start/image-move the collab link rotates — re-read `status.joinLink`
  (or run `ompctl session link NAME`). If empty, bump the recapture annotation
  (`omp.mirantis.io/recapture=$(date +%s)`).
- Restarting a `stopped` session is deferred: the stopped branch takes priority. Set
  `state: running` first, then bump the restart nonce if needed.

## Auth-broker sidecar (automatic token refresh)

For sessions where manual re-auth (when tokens expire) is inconvenient, enable the
`omp auth-broker` sidecar. The sidecar serves credentials on `localhost:9999` and
handles token refresh automatically.

```bash
# Create a session with the auth-broker sidecar
kubectl apply -f - <<EOF
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: work
  namespace: omp-system
spec:
  subtrees: ["shared"]
  authBroker: true
EOF

# Initial auth into the sidecar (exec into the auth-broker container)
ompctl auth work anthropic auth-broker
ompctl auth work gcloud    auth-broker

# After initial auth: broker auto-refreshes; no further action needed.
```

- The broker runs in the `auth-broker` container sharing `$HOME` (PVC) with omp.
- Credentials persist on the PVC and survive pod restarts.
- One-time exec per provider, then automatic refresh until the refresh token itself expires.

## Guardrails

- **Never echo, print, or log a credential value** — not in a command you run, not in
  a prompt you send into the session.
- Each session namespace contains only its own credentials (per-namespace K8s Secret).
  NetworkPolicy blocks cross-namespace pod access.

Switch to the `administrator` skill for cluster lifecycle, platform config, or vault
management.
