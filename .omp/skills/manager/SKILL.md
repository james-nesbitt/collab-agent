---
name: manager
description: Act as the manager for the GKE cluster from this repo — configure the omp platform (ESO ClusterSecretStore, omp-config ConfigMap, GSM credential vault, portable tuning incl. modelRoles, and opt-in mnemopi memory + auto thinking via `tune`) and run sessions (create with injected credentials via Session CR, login, attach, list, kill, share a collab join link) — by driving manager.sh. Use when the user asks to set up or tune omp, add/list a credential or secret, start/share/attach/kill/login a session, or get a collab link. For cluster provisioning/bootstrap/destroy use the `administrator` skill.
---

# Manager

You own omp on the cluster via `./manager.sh`, run from the repo root. It drives
`kubectl` + `gcloud secrets` — no SSH, no tmux send-keys. This role assumes the
[`administrator`](skill://administrator) skill has already bootstrapped the cluster.

Full reference: read `docs/roles/manager.md`.

## Command map

| Intent | Command |
| --- | --- |
| Configure ESO store + omp-config ConfigMap, idempotent | `./manager.sh setup` |
| Store a credential (value on **stdin**) | `printf '%s' "$VAL" \| ./manager.sh vault-add services/github/token` |
| List vault entry NAMES (never values) | `./manager.sh vault-ls [SUBTREE]` |
| Tune local-model features (mnemopi memory, auto thinking) | `./manager.sh tune [--memory] [--thinking]` (no flag = both) |
| Launch a session (Session CR, creds injected) | `./manager.sh new NAME [--subtree SUB]...` |
| Interactive Anthropic OAuth in session pod | `./manager.sh login NAME` |
| Attach to session tmux | `./manager.sh attach [NAME]` |
| List / kill sessions | `./manager.sh list` · `./manager.sh kill NAME` |
| Print collab join link | `./manager.sh collab NAME [view]` |

## Workflows

- **First-time platform setup:** `./manager.sh setup` → expect `SETUP_OK`.
  Re-run after updating `platform/` (image rebuild required to pick up baked assets).
- **Enable local-model features:** `./manager.sh tune --memory` and/or `--thinking`;
  no flag = both. Patches the omp-config ConfigMap; running pods pick it up on restart.
- **Add a credential:** pipe the value on stdin — never as an argument.
  Entry path becomes env var name (`/` and `-` → `_`, uppercased):
  `services/github/token` → `GITHUB_TOKEN`.
- **Model OAuth login:** `new work` then `./manager.sh login work` for interactive
  device-code flow; token persists on the PVC across pod restarts.
  Token-based providers: `vault-add model/anthropic/api-key` + `new --subtree model`.
- **Run a session:** `new work` → `collab work` (copy `omp join "<link>"` to users)
  → `attach work` to drive it.
- **Add per-session skills:** drop `SKILL.md` into the pod's `~/work/.omp/skills/<name>/`
  via `kubectl cp`, then restart the pod (`kubectl delete pod omp -n omp-session-NAME`).

## Guardrails (credentials)

- **Never echo, print, or log a credential value** — not in a command you run,
  not in a prompt you send into the session.
- Each session's namespace contains only its own credentials (per-namespace K8s
  Secret). Guests in a session see that session's injected creds; they cannot
  reach another session's creds (NetworkPolicy + namespace isolation).
- `vault-ls` lists names only; `vault-add` pipes values via stdin (`--data-file=-`).

## Troubleshooting

- **No join link in `collab` output:** operator hasn't captured it yet; `collab`
  automatically triggers a re-capture annotation and waits.
- **A var missing / nothing injected:** check `vault-ls SUBTREE`; empty = nothing synced.
- **Pod stuck in Pending:** check `kubectl describe pod omp -n omp-session-NAME`;
  likely a PVC binding or image pull issue.

Switch to the `administrator` skill for anything about the cluster itself.
