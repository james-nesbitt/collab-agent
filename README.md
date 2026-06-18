# Shared Remote Agent Machine

A single always-on GCP VM hosts an interactive [omp](https://omp.sh) agent session under
tmux. The session is shared to many people and machines via omp **collab** over an
E2E-encrypted relay: the VM runs the agent, repo, toolchain, and docker/podman; guests
join the same live session from any terminal or a browser. Credentials live in a
per-VM vault and are injected into sessions as environment variables, obfuscated so the
model never sees their real values.

## Roles

The tooling is organized around three roles. Two have a script; the third does not.

| Role | Surface | Owns | Doc |
| --- | --- | --- | --- |
| **Administrator** | `administrator.sh` | GCP/VM lifecycle (provision, start/stop, bootstrap, destroy). | [docs/roles/administrator.md](docs/roles/administrator.md) |
| **Manager** | `manager.sh` | omp platform config (secrets, vault, global skills/rules) + per-session lifecycle (create, attach, share). | [docs/roles/manager.md](docs/roles/manager.md) |
| **Operator / joiner** | *(none)* | Works in a shared session via `omp join`; governed by installed rules + skills. | [docs/roles/operator.md](docs/roles/operator.md) |

## Quickstart

```bash
# Administrator — once: make the box and the omp runtime exist
./administrator.sh provision
./administrator.sh bootstrap

# Manager — configure the platform, store a credential, launch a session
./manager.sh setup
./manager.sh tune                 # opt-in: mnemopi memory + auto thinking
printf '%s' "$MY_TOKEN" | ./manager.sh vault-add services/github/token
./manager.sh new work
./manager.sh collab work          # prints:  omp join "<link>"

# Operator — from any machine
omp join "<link>"
```

## Credentials, in one paragraph

`manager.sh new` decrypts a `pass` vault subtree (default `services`) and injects each
entry as an env var (`services/github/token` → `GITHUB_TOKEN`) before launching omp.
Global `secrets.enabled` replaces those values with `#XXXX#` placeholders before any
text reaches the model (**M=PASS**). Two residual exposures are documented, not closed:
joined guests see real values on the de-obfuscated render (**G**), and a value a tool
*prints* persists de-obfuscated to the session transcript (**R**). The installed
`RULES.md` forbids printing secrets; per-session OS isolation (Tier-2) is the unbuilt
fix. Details: [docs/planning/credential-isolation.md](docs/planning/credential-isolation.md).

## Repository layout

```
.omp/skills/                  # project skills: an agent in this repo can act as a role
  administrator/              #   drive administrator.sh (VM lifecycle)
  manager/                    #   drive manager.sh (platform config + sessions)
administrator.sh              # administrator role: VM lifecycle
manager.sh                    # manager role: platform config + sessions
lib/common.sh                 # shared config + gcloud/ssh helpers (sourced)
platform/                     # global assets installed by `manager.sh setup`
  RULES.md                    #   always-apply rules (never print secrets)
  AGENTS.md                   #   machine context for every session
  secrets.yml                 #   secret-shape regex backstops
  rules/                      #   five behaviour/safety rule files
  commands/                   #   slash commands (commit-push-pr)
  skills/credential-access/   #   on-demand credential-access skill
  skills/mirantis-services/   #   JIRA + Confluence via injected env vars
session-template/.omp/        # per-folder config seeded into each new session
docs/
  architecture.md             # system design (topology, trust, lifecycle)
  roles/{administrator,manager,operator}.md
  planning/                   # research + design history
    credential-isolation.md   #   credential design + Tier-2 roadmap
    collab-analysis.md        #   collab mechanism analysis
    local-model-acceleration.md  #   deferred GPU / heavier local-model TODO
```

## Documentation

- [Architecture](docs/architecture.md) — topology, components, credentials, trust
  layering, encryption, network matrix, session lifecycle.
- Roles — [administrator](docs/roles/administrator.md),
  [manager](docs/roles/manager.md), [operator](docs/roles/operator.md).
- Planning — [credential isolation](docs/planning/credential-isolation.md),
  [collab analysis](docs/planning/collab-analysis.md).
