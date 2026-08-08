---
name: credential-rotation
description: What to do when a credential in this session is expired, revoked, or rejected — how to recognise an authentication failure (HTTP 401/403) versus other errors, and the hard rule that credentials can only be rotated from the host by an administrator, never from inside the session. Use when an external service call fails with an auth error, a token looks expired, or you are asked how credentials get refreshed or rotated.
---

# Credential expiry & rotation

Credentials reach this session synced from GCP Secret Manager by the External Secrets
Operator — as **files** under `/etc/omp-creds/` for tools, and as env vars for omp's
own model-provider use (see the `credential-access` skill). They are **read-only**
here: this pod has no write path to Secret Manager, the GCE metadata server
(`169.254.169.254`) is blocked, and ESO only *pulls* values in.
**You cannot rotate a credential from inside the session.** Rotation is a host-side
administrator action.

## Recognise an authentication failure (vs. any other error)

A credential is invalid/expired when the service rejects the *identity*, not the
request shape. Exercise the credential against its service and read the **service's
response** — never the value itself. Auth failures are reported cleanly:

| Service | Invalid-credential signal |
|---|---|
| GitHub API | `HTTP 401` + body `{"message":"Bad credentials"}` |
| Jira / Confluence (Atlassian) | `HTTP 401` + header `x-seraph-loginreason: AUTHENTICATED_FAILED` |
| Most bearer/basic APIs | `HTTP 401 Unauthorized` (identity) or `403 Forbidden` (identity ok, scope missing) |

Distinguish from non-auth errors so you rotate the right thing:

- **401 / 403** → credential problem (expired, revoked, wrong scope). Rotation needed.
- **404** → wrong URL / host / resource — *not* a credential problem.
- **connection refused / DNS / timeout** → network or NetworkPolicy, not the credential.

Check status codes without printing the token (see `credential-access` — never echo a value):

```bash
# GitHub
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $(cat /etc/omp-creds/GITHUB_TOKEN)" \
  https://api.github.com/user            # 200 = valid, 401 = rotate

# Jira (basic auth: email + API token)
curl -s -o /dev/null -w '%{http_code}\n' \
  --user "$(cat /etc/omp-creds/ATLASSIAN_EMAIL):$(cat /etc/omp-creds/ATLASSIAN_TOKEN)" \
  -H "Accept: application/json" https://mirantis.jira.com/rest/api/3/myself
```

If the value is well-formed (right length, no whitespace) but still 401, it is a
**genuine expiry/revocation**, not a storage bug — it must be rotated at the source.

## Rotation happens from the host — not here

When a credential is expired, **report it to the session's host administrator** and
name the exact vault entry, e.g. `users/asmith/atlassian-token`. Do **not** ask the
user to paste a new token into the session, and do not attempt to write it anywhere:
a pasted secret would persist de-obfuscated to the on-disk transcript and show on
every guest's screen.

The administrator rotates it on the host with the platform tooling:

```bash
# On the host (administrator), not in the session:
./administrator.sh vault-add users/<name>/<key>   # prompts for the new value (hidden)
```

`vault-add` writes a new Secret Manager version and (re)grants the ESO service
account access. The credentials reach a running session through two mounts of the
same `omp-creds` Secret, which refresh at different speeds:

- **Files** (`/etc/omp-creds/…`, what tools read) — a mounted Secret volume that
  **kubelet refreshes automatically** (~1 min) once ESO updates the Secret. Since you
  `cat` the file on each call, no restart is needed; just wait for ESO + kubelet.
- **Env vars** (what omp itself uses for model providers) — read once at container
  start, so they only refresh on **pod restart**.

ESO first has to pull the new version into the Secret. To make that immediate rather
than waiting for its `refreshInterval` (~1h), the administrator can force it on the host:

```bash
# On the host (administrator):
kubectl annotate externalsecret omp-creds -n omp-session-<name> force-sync=$(date +%s) --overwrite
# then, if the rotated credential is one omp itself uses (a model-provider key):
kubectl delete pod omp-0 -n omp-session-<name>   # PVC-backed $HOME survives
```

After rotation, re-run the status-code check above to confirm the credential now
returns `200`.

## Summary

- You **detect** expiry here (exercise the credential, read the service's 401/403).
- You **cannot fix** it here — no write path to the vault by design.
- The **host administrator rotates** it with `vault-add`; ESO re-syncs it in.
- Report the failing entry by name; never paste or print a secret.
