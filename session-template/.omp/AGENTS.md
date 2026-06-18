# Session: __SESSION_NAME__

This is the omp session `__SESSION_NAME__` running in pod `omp` in namespace
`omp-session-__SESSION_NAME__` on the `omp-cluster` GKE cluster.

- To add a skill mid-engagement, drop it into `.omp/skills/<name>/SKILL.md` and restart
  the session (`./manager.sh kill __SESSION_NAME__` then `./manager.sh new __SESSION_NAME__`).
  Session state (auth tokens + ~/work) persists on the PVC across restarts.
- Machine-wide context, credential handling, and collab etiquette are in the global
  `~/.omp/agent/AGENTS.md` and `~/.omp/agent/RULES.md`.
