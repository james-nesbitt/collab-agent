---
name: credential-access
description: How to discover and use credentials on this shared omp host. Use when a task needs an API token, key, password, or other secret to call an external service (e.g. GitHub, cloud APIs). Explains that credentials arrive as environment variables, how to find them by name, and the hard rule never to print their values.
---

# Credential access

Credentials for this machine are injected as **environment variables** when the
session starts, decrypted from a per-VM `pass` vault. You never fetch them yourself —
they are already in the process environment.

## Naming

Each vault entry maps to an env var by its path under the injected subtree, with `/`
and `-` replaced by `_` and uppercased. Examples:

- `services/github/token`   → `GITHUB_TOKEN`
- `services/aws/access-key` → `AWS_ACCESS_KEY`

## Discover what's available (NAMES only)

List the names without ever revealing a value:

```bash
printenv | sed 's/=.*//' | grep -Ei 'token|key|secret|password'
```

## Use a credential — inline only

Reference the variable directly in the command that consumes it. Never expand it into
output, a file, or an intermediate variable you print:

```bash
curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user
```

## The model never sees the real value

Global `secrets.enabled` obfuscation replaces secret values with `#XXXX#` placeholders
before anything reaches the model. That protects the model — it does **not** protect
the transcript or guests:

- **Never print, echo, `cat`, or log a value.** A tool result containing the real value
  is persisted de-obfuscated into the session transcript on disk.
- **Assume every joined guest sees anything printed.** Guests are inside the credential
  trust boundary and see the de-obfuscated screen.

If you need to confirm a credential works, exercise it against its service (as above)
and inspect the service's response — never the value itself.
