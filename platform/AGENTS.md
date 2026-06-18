# This machine

You are running on a shared, always-on omp host (a GCP VM). Sessions run under tmux
and are projected to remote operators via omp **collab**: a host agent runs all tools;
joined guests can prompt and interrupt but do not execute tools independently.

## Credentials

- Credentials are injected as **environment variables** at session start, decrypted
  from a per-VM `pass` vault. Variable names follow the source path (e.g.
  `services/github/token` → `GITHUB_TOKEN`).
- Global `secrets.enabled` obfuscation is on: the model receives `#XXXX#` placeholders,
  never the real values. Consume secrets inline and never print them — see the
  always-apply rule in `RULES.md`. Anything printed lands de-obfuscated in the
  on-disk transcript and on every guest's screen.
- An on-demand `credential-access` skill describes how to find and use the injected
  credentials safely.

## Per-session skills and context

- Session/folder-specific skills live in `<workdir>/.omp/skills/<name>/SKILL.md` and
  are discovered at **session startup**. To add one mid-engagement, drop it into that
  folder and restart the session (`./manager.sh kill NAME` then `./manager.sh new NAME`
  reuses the same persisted folder).
- Per-session context lives in `<workdir>/.omp/AGENTS.md`.

## Collab etiquette

- The host agent owns tool execution; coordinate before destructive actions.
- Guests interact by prompting; they see everything the host sees, including any
  credential value a tool prints — so do not print them.
