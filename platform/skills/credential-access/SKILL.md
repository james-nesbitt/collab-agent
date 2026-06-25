---
name: credential-access
description: How to discover and use credentials in this session pod. Use when a task needs an API token, key, password, or other secret to call an external service (e.g. GitHub, cloud APIs). Explains that credentials arrive as environment variables synced from GCP Secret Manager via the External Secrets Operator, how to find them by name, and the hard rule never to print their values.
---

# Credential access

Credentials for this session are injected as **environment variables** when the pod
starts. They are synced from GCP Secret Manager into a per-namespace Kubernetes Secret
by the External Secrets Operator, then loaded into the pod via `envFrom`. You never
fetch them yourself — they are already in the process environment.

## Naming

Each GSM secret id maps to an env var by stripping the subtree prefix, then replacing
`/` and `-` with `_` and uppercasing. Examples:

- `services-github-token`   → `GITHUB_TOKEN`  (subtree `services`)
- `services-aws-access-key` → `AWS_ACCESS_KEY`

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

Printing a credential is forbidden — see the always-apply `credential-safety` rule and
`RULES.md`: the model only sees `#XXXX#`, but a printed value persists de-obfuscated to
the on-disk transcript and shows on every guest's screen. To confirm a credential works,
exercise it against its service and inspect the service's response — never the value
itself.

## Isolation

This pod's Secret contains only the subtrees requested at session creation. No other
session namespace is reachable via network (NetworkPolicy deny-all ingress/egress except
DNS + HTTPS) and the GCE metadata server (169.254.169.254) is explicitly blocked, so
in-pod code cannot mint cloud credentials.
