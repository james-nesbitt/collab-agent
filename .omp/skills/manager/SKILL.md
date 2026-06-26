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
| Restart pod / re-pull latest image | `kubectl annotate session NAME -n omp-system omp.mirantis.io/restartedAt=$(date +%s) --overwrite` |
| Move to a pinned image | `kubectl patch session NAME -n omp-system --type=merge -p '{"spec":{"image":"ghcr.io/james-nesbitt/collab-agent/omp-session:sha-XXXX"}}'` |
| Check auth state in pod | `kubectl exec -n omp-session-NAME omp -- bash -lc 'omp auth status 2>&1 \|\| true'` |
| Override auth (Anthropic SSO) | `kubectl exec -it -n omp-session-NAME omp -- bash -lc 'omp auth login anthropic'` |
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

- **Launch and share (Anthropic SSO):**
  1. Apply Session CR; wait for `Running`.
  2. Login inside the pod (device-code flow — browser not required in pod):
     ```bash
     kubectl exec -it -n omp-session-work omp -- bash -lc 'omp auth login anthropic'
     ```
     Complete the device-code flow in your browser. Token saves to PVC; survives restarts.
  3. If omp is in the setup wizard, dismiss it first:
     ```bash
     kubectl exec -n omp-session-work omp -- bash -lc 'tmux send-keys -t omp Escape Escape Escape'
     ```
  4. Trigger collab link capture:
     ```bash
     kubectl annotate session work -n omp-system \
       omp.mirantis.io/recapture=$(date +%s) --overwrite
     sleep 15
     kubectl get session work -n omp-system -o jsonpath='{.status.joinLink}'
     ```
  5. Hand the link to operators.

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
- **Restart** (bump `omp.mirantis.io/restartedAt`) re-pulls the current image tag and
  resumes the conversation.
- **Image move** (`spec.image`) pins a specific digest and recreates the pod.
- `kubectl delete session` is the **only** operation that destroys the PVC.
- After restart/start/image-move the collab link rotates — re-read `status.joinLink`.
  If empty, bump the recapture annotation (`omp.mirantis.io/recapture=$(date +%s)`).
- Restarting a `stopped` session is deferred: the stopped branch takes priority. Set
  `state: running` first, then bump the restart nonce if needed.

## Guardrails

- **Never echo, print, or log a credential value** — not in a command you run, not in
  a prompt you send into the session.
- Each session namespace contains only its own credentials (per-namespace K8s Secret).
  NetworkPolicy blocks cross-namespace pod access.

Switch to the `administrator` skill for cluster lifecycle, platform config, or vault
management.
