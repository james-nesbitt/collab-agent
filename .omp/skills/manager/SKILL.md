---
name: manager
description: Act as the manager for the omp-agent VM from this repo — configure the omp platform (enable secret obfuscation, the pass credential vault, global skills/RULES.md/AGENTS.md) and run sessions (create with injected credentials, attach, list, kill, share a collab join link) — by driving manager.sh. Use when the user asks to set up omp, add/list a credential or secret, start/share/attach/kill a session, or get a collab link. For VM provisioning/start/stop use the `administrator` skill.
---

# Manager

You own omp on the VM via `./manager.sh`, run from the repo root. It drives the VM over
`gcloud ssh` + IAP, including the interactive omp TUI through `tmux send-keys` /
`capture-pane`. This role assumes the [`administrator`](skill://administrator) skill has
already provisioned and bootstrapped the VM and it is `RUNNING`.

Full reference: read `docs/roles/manager.md`. Credential design and the trust boundary:
`docs/planning/credential-isolation.md`.

## Command map

| Intent | Command |
| --- | --- |
| Configure platform (secrets + vault + global assets), idempotent | `./manager.sh setup` |
| Store a credential (value on **stdin**) | `printf '%s' "$VAL" \| ./manager.sh vault-add services/github/token` |
| List vault entry NAMES (never values) | `./manager.sh vault-ls [SUBTREE]` |
| Launch a session (creds injected) | `./manager.sh new NAME [--subtree SUB]` |
| Share + print join link | `./manager.sh collab NAME [view]` |
| Attach / list / kill | `./manager.sh attach [NAME]` · `./manager.sh list` · `./manager.sh kill NAME` |

## Workflows

- **First-time platform setup:** `./manager.sh setup` → expect `SETUP_OK` and four
  installed `~/.omp/agent/` paths. Re-run after editing anything under `platform/`.
- **Add a credential:** pipe the value in on stdin — never pass it as an argument.
  The entry path becomes an env-var name (`/` and `-` → `_`, uppercased), so
  `services/github/token` → `GITHUB_TOKEN`. End entries with a secret keyword
  (`token`/`key`/`secret`/`password`) so auto-obfuscation fires; otherwise add a
  value-shape regex to `platform/secrets.yml` and re-run `setup`.
- **Run a session for someone:** `new work` → `collab work` (copy the printed
  `omp join "<link>"` to the user) → `attach work` if you want to drive it.
- **Add per-session skills:** drop them into `~/sessions/<name>/.omp/skills/` on the VM,
  then `kill` + `new` (the folder persists; skills load at session start).

## Guardrails (credentials)

- **Never echo, print, `cat`, or log a credential value** — not in a command you run,
  not in a prompt you send into the session. A value a tool prints persists
  de-obfuscated to the session `.jsonl` and shows on every participant's screen.
- The model only sees `#XXXX#` placeholders (verified), but **joined guests see real
  values**. Don't share a session's collab link with anyone who shouldn't see the
  credentials in its injected subtree — there is no per-joiner hiding yet (Tier-2).
- `vault-ls` and `vault-add` deal in names only; never read or surface a stored value.

## Troubleshooting

- **`collab` says "No join link found" + dumps the pane:** an old session in a narrow
  pane wrapped the link. Sessions from `new` use a wide pane — `kill` then `new`.
- **A var is missing / nothing injected:** check `vault-ls SUBTREE`; an empty subtree
  makes `new` warn and launch without creds.

Switch to the `administrator` skill for anything about the VM itself (provision, start,
stop, destroy).
