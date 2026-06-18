# Session: __SESSION_NAME__

This is the omp session `__SESSION_NAME__` on the shared agent host.

- Session-scoped skills go in `.omp/skills/<name>/SKILL.md` (relative to this folder)
  and are discovered when the session starts. After adding one, restart the session
  (`./manager.sh kill __SESSION_NAME__` then `./manager.sh new __SESSION_NAME__`).
- Machine-wide context, credential handling, and collab etiquette are in the global
  `~/.omp/agent/AGENTS.md` and `~/.omp/agent/RULES.md`.
