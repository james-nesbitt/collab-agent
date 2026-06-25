# This machine

You are running in an isolated Kubernetes pod (namespace `omp-session-<name>` on the
`omp-cluster` GKE cluster). Sessions run under tmux and are projected to remote
operators via omp **collab**: a host agent runs all tools; joined guests can prompt
and interrupt but do not execute tools independently.

## Credentials

- Credentials are injected as **environment variables** at pod start, synced from
  GCP Secret Manager into this pod's namespace-scoped Kubernetes Secret by the
  External Secrets Operator. Variable names follow the source path (e.g.
  `services/github/token` → `GITHUB_TOKEN`).
- This pod's Secret holds only the subtrees requested when the session was created.
  No other session's credentials are accessible from this namespace.
- Global `secrets.enabled` obfuscation is on: the model receives `#XXXX#` placeholders,
  never the real values. Consume secrets inline and never print them — see the
  always-apply rule in `RULES.md`. Anything printed lands de-obfuscated in the
  on-disk transcript and on every guest's screen.
- An on-demand `credential-access` skill describes how to find and use the injected
  credentials safely.

## Operator identities

- A session may carry one or more **operators** — humans on whose behalf you act in
  external services. An operator's identity is injected as `[<NS>_]OPERATOR_NAME` /
  `[<NS>_]OPERATOR_EMAIL` (not secret) and their service credentials are namespaced
  the same way (e.g. `<NS>_ATLASSIAN_*`). A bare `OPERATOR_*` (no prefix) means a
  single-operator session.
- Before any action that uses a service credential — **read or write** — you MUST
  establish which operator you are acting as: see the `mirantis-services` skill's
  "Determine the acting operator". With two or more operators, NEVER infer who from
  the session home directory, cwd, or OS username — require an explicit name in the
  prompt or challenge the user. State who you resolved to.
- These identities are **advisory and unauthenticated**: any joined participant can
  claim any name, and every joiner shares the screen and all injected credentials.
  This selects which credential to act with — it is not isolation between joiners.

## Per-session skills and context

- Session/folder-specific skills live in `<workdir>/.omp/skills/<name>/SKILL.md` and
  are discovered at **session startup**. To add one mid-engagement, drop it into
  that folder and restart the pod.
- Per-session context lives in `<workdir>/.omp/AGENTS.md`.

## Collab etiquette

- The host agent owns tool execution; coordinate before destructive actions.
- Guests interact by prompting; they see everything the host sees, including any
  credential value a tool prints — so do not print them.
