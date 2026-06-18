# Credential handling — always apply

This is a shared, collab-projected omp host. Credentials are injected into the
session as environment variables. The following rules are non-negotiable for every
participant (host agent and any joined guest).

- **Never echo, print, `cat`, or log a credential.** Do not run `printenv`,
  `env`, `echo "$X_TOKEN"`, or any command whose output contains a secret value.
  Reference a secret only inline in the command that consumes it, e.g.
  `curl -H "Authorization: Bearer $GITHUB_TOKEN" …`.
  Rationale: the model only ever sees `#XXXX#` placeholders, but a tool result that
  prints the real value is persisted de-obfuscated to the session transcript on disk
  **and** is visible on screen to every joined guest.

- **Never write a secret value to disk** — not to a file, a heredoc, a temp file, or
  a config you create. Pass it through the process environment only.

- **To discover what credentials exist, read NAMES only, never values**, e.g.
  `printenv | sed 's/=.*//' | grep -Ei 'token|key|secret|password'`.

- **Treat the collab join link as a secret.** Anyone with the link joins the session
  inside the credential trust boundary. Share it only with intended operators.
