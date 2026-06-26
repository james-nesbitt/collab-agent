---
name: manager
description: Act as the manager for the GKE cluster from this repo — run sessions (create with injected credentials via Session CR, login, attach, list, kill, share a collab join link) directly with kubectl. Use when the user asks to start, share, attach, login, list, or kill a session, or get a collab link. For cluster provisioning/bootstrap/destroy, platform config (setup/tune), or credential vault (vault-add/vault-ls) use the `administrator` skill.
---

# Manager

You manage sessions on the cluster directly with `kubectl`. There is no manager
script. Platform config and vault operations are handled by `./administrator.sh`
— see the [`administrator`](skill://administrator) skill.

Full reference: read `docs/roles/manager.md`.

## Prerequisites

kubectl configured for the cluster. Check with:
```bash
kubectl config current-context  # should be gke_<project>_<zone>_omp-cluster
```
Or refresh: `./administrator.sh credentials`.

Session CRs live in namespace `omp-system`. Session pods run in `omp-session-<name>`.

## Create a session

```bash
kubectl apply -f - <<EOF
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: work
  namespace: omp-system
spec:
  subtrees: ["services"]
  view: false
EOF
```

Repeat `--subtrees` by listing more entries, e.g. `["services", "model"]`.

Wait for the session to reach `Hosting`:
```bash
kubectl wait --for=jsonpath='{.status.phase}'=Hosting \
  session/work -n omp-system --timeout=180s
```

## Command map

| Intent | Command |
| --- | --- |
| List all sessions | `kubectl get sessions -n omp-system` |
| Session status / phase | `kubectl get session NAME -n omp-system -o jsonpath='{.status.phase}'` |
| Kill session (destroys namespace + PVC) | `kubectl delete session NAME -n omp-system` |
| Stop session (keep PVC + namespace) | `kubectl patch session NAME -n omp-system --type=merge -p '{"spec":{"state":"stopped"}}'` |
| Start a stopped session | `kubectl patch session NAME -n omp-system --type=merge -p '{"spec":{"state":"running"}}'` |
| Restart (always moves to latest image) | `kubectl patch session NAME -n omp-system --type=merge -p "{\"spec\":{\"image\":null},\"metadata\":{\"annotations\":{\"omp.mirantis.io/restartedAt\":\"$(date +%s)\"}}}"` |
| Move to a pinned image | `kubectl patch session NAME -n omp-system --type=merge -p '{"spec":{"image":"ghcr.io/james-nesbitt/collab-agent/omp-session:sha-XXXX"}}'` |
| Auth a provider in a session | `./administrator.sh auth NAME PROVIDER` — providers: `anthropic` `gcloud` `aws` `az` `gh` |
| Port-forward for browser OAuth | `./administrator.sh port-forward NAME LOCAL_PORT` |
| Transfer local session to GKE pod | `./administrator.sh session-transfer NAME [LOCAL_DIR] [SESSION_ID]` |
| Skip setup wizard in tmux | `kubectl exec -n omp-session-NAME omp -- bash -lc 'tmux send-keys -t omp Escape Escape Escape'` |
| Attach to session tmux | `kubectl exec -it -n omp-session-NAME omp -- tmux attach -t omp` |
| Get collab join link | `kubectl get session NAME -n omp-system -o jsonpath='{.status.joinLink}'` |
| Get view-only link | `kubectl get session NAME -n omp-system -o jsonpath='{.status.viewLink}'` |
| Trigger link re-capture | `kubectl annotate session NAME -n omp-system omp.mirantis.io/recapture=$(date +%s) --overwrite` |
| Inspect session events | `kubectl describe session NAME -n omp-system` |
| Check pod logs | `kubectl logs -n omp-session-NAME omp` |
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
     ./administrator.sh auth work anthropic
     ```
     Token saves to PVC; survives restarts. One-time per session.
  3. Dismiss setup wizard if omp is waiting:
     ```bash
     kubectl exec -n omp-session-work omp -- bash -lc 'tmux send-keys -t omp Escape Escape Escape'
     ```
  4. Trigger collab link capture and hand to operators.

- **Authenticate a cloud CLI (gcloud / aws / az):**
  ```bash
  ./administrator.sh auth work gcloud      # device code → gcloud ADC on PVC
  ./administrator.sh auth work aws         # device code SSO login (profile must exist)
  ./administrator.sh auth work aws-configure  # interactive SSO wizard (browser redirect)
  ./administrator.sh auth work az          # device code → Azure token on PVC
  ```
  Credentials are stored under `$HOME` on the session PVC and survive pod restarts.
  Re-auth only needed when the token expires (gcloud/az: never for refresh; aws SSO: per portal policy ~8–12 h).

- **Authenticate GitHub (paste token):**
  ```bash
  printf '%s' "$MY_PAT" | ./administrator.sh auth work gh
  ```
  Alternatively, store the PAT in GSM (`vault-add services/github/token`) and inject via `omp-creds`.

- **If the browser-redirect OAuth can't open a browser in the pod** (e.g. `aws configure sso`):
  ```bash
  # Terminal 1
  ./administrator.sh port-forward work 8400
  # Terminal 2
  kubectl exec -it -n omp-session-work omp -- bash -lc \
    'aws configure sso --redirect-url http://localhost:8400/callback'
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
  kubectl exec -n omp-session-NAME omp -- bash -lc '
    echo "GEMINI_API_KEY set: $([ -n "$GEMINI_API_KEY" ] && echo yes || echo no)"
    echo "ANTHROPIC_OAUTH_TOKEN set: $([ -n "$ANTHROPIC_OAUTH_TOKEN" ] && echo yes || echo no)"
    echo "ANTHROPIC_REFRESH_TOKEN set: $([ -n "$ANTHROPIC_REFRESH_TOKEN" ] && echo yes || echo no)"
  '
  ```

## Troubleshooting

- **Session stuck in Pending/Provisioning:** `kubectl describe session NAME -n omp-system`
  — check operator logs for ExternalSecret or pod errors.
- **ExternalSecret not Valid:** GSM labels mismatch or ClusterSecretStore not ready —
  re-run `./administrator.sh setup`.
- **Pod stuck / image pull error:** `kubectl describe pod omp -n omp-session-NAME` —
  check image tag and GHCR package visibility (must be public for anonymous pull).

## Session lifecycle notes

- **Stop** (`state: stopped`) removes the pod only — namespace, PVC, secrets, and
  NetworkPolicies are retained. The conversation is preserved on the PVC.
- **Start** (`state: running`) recreates the pod and resumes the omp session via `-c`.
- **Restart** (combined patch: clears `spec.image` + bumps `restartedAt`) always moves
  to the latest published image and resumes the conversation from the PVC.
- **Image move** (`spec.image`) pins a specific digest and recreates the pod.
- `kubectl delete session` is the **only** operation that destroys the PVC.
- After restart/start/image-move the collab link rotates — re-read `status.joinLink`.
  If empty, bump the recapture annotation (`omp.mirantis.io/recapture=$(date +%s)`).
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
  subtrees: ["services"]
  authBroker: true
EOF

# Initial auth into the sidecar (exec into the auth-broker container)
./administrator.sh auth work anthropic auth-broker
./administrator.sh auth work gcloud    auth-broker

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
