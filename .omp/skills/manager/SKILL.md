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
| Kill session (GCs namespace + PVC) | `kubectl delete session NAME -n omp-system` |
| Anthropic OAuth inside pod | `kubectl exec -it -n omp-session-NAME omp -- bash -lc 'omp auth login'` |
| Attach to session tmux | `kubectl exec -it -n omp-session-NAME omp -- tmux attach -t omp` |
| Get collab join link | `kubectl get session NAME -n omp-system -o jsonpath='{.status.joinLink}'` |
| Get view-only link | `kubectl get session NAME -n omp-system -o jsonpath='{.status.viewLink}'` |
| Trigger link re-capture | `kubectl annotate session NAME -n omp-system omp.mirantis.io/recapture=$(date +%s) --overwrite` |
| Inspect session events | `kubectl describe session NAME -n omp-system` |
| Check pod logs | `kubectl logs -n omp-session-NAME omp` |
| Check operator logs | `kubectl logs -n omp-system deploy/omp-operator` |

## Workflows

- **Launch and share:**
  1. Apply Session CR (above); wait for Hosting.
  2. Get link: `kubectl get session work -n omp-system -o jsonpath='{.status.joinLink}'`
  3. Hand `omp join "<link>"` to operators.

- **Token-based model auth:** store with `./administrator.sh vault-add model/anthropic/api-key`
  and create session with `subtrees: ["services", "model"]`. The pod injects
  `ANTHROPIC_API_KEY` — no OAuth login needed.

- **Interactive OAuth login:** after session is Running/Hosting, `kubectl exec -it` into
  the pod and run `omp auth login`. Token persists on the PVC across restarts.

- **If collab link is empty** (pod just restarted): trigger re-capture annotation and
  wait ~30 s, then re-read `status.joinLink`.

## Troubleshooting

- **Session stuck in Pending/Provisioning:** `kubectl describe session NAME -n omp-system`
  — check operator logs for ExternalSecret or pod errors.
- **ExternalSecret not Valid:** GSM labels mismatch or ClusterSecretStore not ready —
  re-run `./administrator.sh setup`.
- **Pod stuck / image pull error:** `kubectl describe pod omp -n omp-session-NAME` —
  check image tag and GHCR package visibility (must be public for anonymous pull).

## Guardrails

- **Never echo, print, or log a credential value** — not in a command you run, not in
  a prompt you send into the session.
- Each session namespace contains only its own credentials (per-namespace K8s Secret).
  NetworkPolicy blocks cross-namespace pod access.

Switch to the `administrator` skill for cluster lifecycle, platform config, or vault
management.
