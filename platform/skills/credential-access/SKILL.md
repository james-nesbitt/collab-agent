---
name: credential-access
description: How to discover and use credentials in this session pod. Use when a task needs an API token, key, password, or other secret to call an external service (e.g. GitHub, Jira, cloud APIs). Explains that credentials are delivered as files under /etc/omp-creds (the version-independent path, since some omp builds hide credential env vars from tool subprocesses), how to find them by name, and the hard rule never to print their values.
---

# Credential access

Credentials for this session are delivered as **files** under `/etc/omp-creds/`, synced
from GCP Secret Manager into a per-namespace Kubernetes Secret by the External Secrets
Operator and mounted read-only. **Read them from files, not the environment.**

## Why files, not `$ENV_VARS`

Read credentials from the files — **not** from the environment. How omp exposes
credential env vars to tool subprocesses (the bash/python your tools run in) varies by
omp version: some builds **scrub** them (so `$GITHUB_TOKEN` and `$ATLASSIAN_TOKEN` expand
to *empty* and `os.environ` omits them), others pass them through obfuscated. The files
are the one path that behaves the same on every version. So do **not** conclude "the
credential isn't injected" from an empty env var or `os.environ` check — that check is
unreliable here. The credential always lives in `/etc/omp-creds/<NAME>`; read it there.

## Discover what's available (NAMES only)

```bash
ls /etc/omp-creds/          # e.g. ATLASSIAN_EMAIL  ATLASSIAN_TOKEN  GITHUB_TOKEN  OLLAMA_CLOUD_API_KEY
```

The file name is the credential name (GSM secret id with its subtree prefix stripped,
`/` and `-` → `_`, uppercased). The file **content** is the value.

## Use a credential — inline only

Read the file *inside* the command that consumes it, with `$(cat …)`. Never copy it into
a variable, file, or output you then print:

```bash
# GitHub
curl -fsS -H "Authorization: Bearer $(cat /etc/omp-creds/GITHUB_TOKEN)" https://api.github.com/user

# Jira / Confluence (basic auth: email + API token)
curl -fsS -u "$(cat /etc/omp-creds/ATLASSIAN_EMAIL):$(cat /etc/omp-creds/ATLASSIAN_TOKEN)" \
  -H "Accept: application/json" https://mirantis.jira.com/rest/api/3/myself
```

## Never reveal a value

Printing a credential is forbidden — see the always-apply `credential-safety` rule and
`RULES.md`. Never `cat` a cred file to output, never `-v`/`--trace` a curl (it prints the
auth header), never echo `$(cat …)`. The value substituted into a tool argument is
obfuscated to `#XXXX#` for the model, but a value printed to stdout persists de-obfuscated
to the on-disk transcript and shows on every guest's screen. To confirm a credential
works, exercise it against its service and inspect the **service's response** (e.g. the
HTTP status or the returned identity) — never the value itself.

## When a credential is missing or rejected

- **File absent** in `/etc/omp-creds/` → the subtree wasn't requested at session
  creation. This is a session-config matter for the administrator.
- **File present but the service returns 401/403** → the credential is expired/revoked.
  See the `credential-rotation` skill — rotation is host-side only.

## Isolation

This pod's Secret contains only the subtrees requested at session creation. No other
session namespace is reachable via network (NetworkPolicy deny-all ingress/egress except
DNS + HTTPS) and the GCE metadata server (169.254.169.254) is explicitly blocked, so
in-pod code cannot mint cloud credentials.
