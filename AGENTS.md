# Remote Agent Machine — Agent Entry Point

This repo runs a shared, always-on [oh-my-pi](https://github.com/can1357/oh-my-pi)
(`omp`) coding agent on GKE. If you're an agent (or a human) checking out this repo
to operate the platform, start here.

## Skills

Role-specific instructions live in [`skills/`](skills/) — one `SKILL.md` per role:

| Role | Skill | Use it to |
| --- | --- | --- |
| Administrator | [`skills/administrator/SKILL.md`](skills/administrator/SKILL.md) | Provision/destroy the GKE cluster via Terraform, manage the GSM credential vault, onboard teams |
| Manager | [`skills/manager/SKILL.md`](skills/manager/SKILL.md) | Create, share, list, stop/start/restart, and kill sessions |
| Operator | [`skills/operator/SKILL.md`](skills/operator/SKILL.md) | Join a shared session as a guest and work in it |

Read [docs/architecture.md](docs/architecture.md) first for the full system picture,
then the skill for your role.

## Using these skills with omp

This repo's own operational tooling assumes `omp` — realistically, nothing else can
drive a GKE cluster, GCP Secret Manager, and this repo's `ompctl`/`administrator.sh`
scripts sanely without it. `omp` discovers project skills at `.omp/skills/<name>/SKILL.md`
relative to the working directory; `.omp/skills` here is a symlink to the top-level
`skills/` folder above, so an `omp` session started at the repo root picks these up
automatically with zero extra setup.

Skills content itself lives at the top level (not nested under `.omp/`) so it stays
plain, portable markdown — readable and referenceable without any tool-specific
convention, and easy to point another harness's own project-skill mechanism at if one
exists (symlink or copy `skills/<name>` into that harness's expected location).

## Other entry points

- [README.md](README.md) — quickstart commands (stand up cluster → create session → join)
- [docs/architecture.md](docs/architecture.md) — full system design, topology, trust model
- [docs/relay.md](docs/relay.md) — self-hosted collab relay: how it works, health checks, troubleshooting
- [docs/farm-out-execution.md](docs/farm-out-execution.md) — driving a remote session directly via `kubectl exec` + tmux to farm out long-running tasks without holding a local connection open
- [docs/roles/](docs/roles/) — long-form guides backing each skill above
- [docs/access-control.md](docs/access-control.md) — team onboarding, IAM/RBAC model
