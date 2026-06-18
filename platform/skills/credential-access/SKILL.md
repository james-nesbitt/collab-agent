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

## Never reveal a value

Printing a credential is forbidden — see the always-apply `credential-safety` rule and the
collab-host `RULES.md`: the model only sees `#XXXX#`, but a printed value persists
de-obfuscated to the on-disk transcript and shows on every guest's screen. To confirm a
credential works, exercise it against its service (as above) and inspect the service's
response — never the value itself.
