# This collab host — always apply

This is a shared omp host projected to remote operators via collab. Credentials are
injected into the session as environment variables. The general "never surface a secret
value" policy lives in the always-apply `credential-safety` rule; the points below are the
collab-host additions on top of it, binding every participant (host agent and any guest).

- **Anything printed is exposed twice over.** The model only ever sees `#XXXX#`
  placeholders, but a tool result that prints a real credential value is persisted
  **de-obfuscated** to the session transcript on disk **and** shows on the screen of every
  joined guest. Consume secrets inline (`curl -H "Authorization: Bearer $GITHUB_TOKEN" …`),
  never in a command whose output carries the value.

- **Never write a secret value to disk** — not to a file, heredoc, temp file, or a config
  you create. Pass it through the process environment only.

- **Treat the collab join link as a secret.** Anyone with the link joins inside the
  credential trust boundary and sees everything on the host's screen. Share it only with
  intended operators.
