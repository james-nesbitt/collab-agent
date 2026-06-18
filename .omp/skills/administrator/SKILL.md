---
name: administrator
description: Act as the administrator for the omp-agent GCP VM from this repo — provision, start/stop, bootstrap the omp runtime, open an SSH shell, check status/IP, and destroy. Use when the user asks to create, boot up, stop, bootstrap, check on, get the IP of, or tear down the VM. This is infrastructure only; for omp config, the vault, or sessions use the `manager` skill.
---

# Administrator

You drive the **GCP VM lifecycle** via `./administrator.sh`, run from the repo root.
All access tunnels over `gcloud ssh` + IAP. This role is pure infrastructure: make the
box and the `omp` runtime exist. Anything about omp itself — `secrets.enabled`, the
credential vault, sessions, collab — is the [`manager`](skill://manager) skill, not you.

Full reference: read `docs/roles/administrator.md`.

## Preconditions

- `gcloud` is installed and authenticated (`gcloud auth login`).
- Project/instance defaults: `tools-348616` / `omp-agent` / zone `europe-west1-b`.
  Override per-command with env vars (`INSTANCE_NAME`, `ZONE`, `REGION`,
  `MACHINE_TYPE`, `DISK_SIZE`, `DISK_TYPE`, `STATIC_IP_NAME`, `USE_IAP`).

## Command map

| Intent | Command |
| --- | --- |
| Create VM + reserve static IP (once) | `./administrator.sh provision` |
| Install tmux + mise/bun/omp (once per OS-Login user) | `./administrator.sh bootstrap` |
| Boot a stopped VM | `./administrator.sh start` |
| Stop to save cost (disk persists) | `./administrator.sh stop` |
| Status / IP | `./administrator.sh status` · `./administrator.sh ip` |
| Shell on the VM | `./administrator.sh ssh [-- EXTRA_ARGS]` |
| Permanently delete VM + IP | `./administrator.sh destroy` |

`provision`, `bootstrap`, and `status` are idempotent. After `bootstrap`, hand off:
the `manager` skill runs `./manager.sh setup`.

## Workflows

- **Stand up from scratch:** `provision` → `bootstrap`, confirm `omp --version` prints
  in the bootstrap output, then tell the user to use the manager skill for `setup`.
- **Bring online / park:** `start` / `stop`. Check `status` first to avoid a no-op.
- **Inspect:** `status` for run state + IP; `ssh` for a shell.

## Guardrails

- `destroy` is irreversible and takes the disk with it — it prompts for `yes`; never
  pre-answer it, and surface the warning to the user before running.
- Do **not** edit omp config, the vault, or sessions from this role. If the problem is a
  *session* (not the VM), switch to the `manager` skill.
- These scripts never push or open PRs; follow the repo's git rules for any commits.
