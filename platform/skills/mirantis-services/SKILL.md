---
name: mirantis-services
description: Query and update Mirantis JIRA and Confluence using the Atlassian credentials delivered to this session as files. Use when the user asks to read, search, create, or update JIRA issues or Confluence pages.
---

# Mirantis Services (JIRA + Confluence)

JIRA and Confluence share one Atlassian Cloud account. Credentials are delivered as
**files** under `/etc/omp-creds/` (see the `credential-access` skill) — omp hides
credential env vars from tool subprocesses, so read them from the files, never from
`$ENV`:

| file | contents |
|---|---|
| `/etc/omp-creds/ATLASSIAN_EMAIL` | Atlassian account email |
| `/etc/omp-creds/ATLASSIAN_TOKEN` | Atlassian API token |

These come from the per-user vault subtree (`users/<name>/atlassian-email` and
`users/<name>/atlassian-token` in GCP Secret Manager). The administrator adds/rotates
them on the **host** with `./administrator.sh vault-add users/<name>/atlassian-token`
(see the `credential-rotation` skill). If a file is absent the subtree wasn't requested
at session creation; if a call returns 401, the token is expired — rotation is host-side.

## Auth pattern — read from files, inline only

Set the basic-auth pair once from the files, then reference it; **never echo `$AUTH`**,
never `cat` a cred file to output, never pass `-v`/`--trace` (it prints the auth header):

```bash
AUTH="$(cat /etc/omp-creds/ATLASSIAN_EMAIL):$(cat /etc/omp-creds/ATLASSIAN_TOKEN)"

# status-code-only check (no headers/body printed)
curl -fsS -o /dev/null -w '%{http_code}\n' -u "$AUTH" -H "Accept: application/json" <URL>
```

## Base URLs

- JIRA: `https://mirantis.jira.com`
- Confluence: `https://mirantis.jira.com/wiki`  <!-- unverified — confirm Confluence base URL; if a request 404s, this is the literal to fix -->

---

## JIRA (REST API v3)

```bash
BASE=https://mirantis.jira.com
AUTH="$(cat /etc/omp-creds/ATLASSIAN_EMAIL):$(cat /etc/omp-creds/ATLASSIAN_TOKEN)"

# Get an issue
curl -fsS -u "$AUTH" -H "Accept: application/json" "$BASE/rest/api/3/issue/PROJ-123"

# Search with JQL
curl -fsS -u "$AUTH" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/search" \
  -d '{"jql":"project=FOO AND status=\"In Progress\"","maxResults":50}'

# Create an issue
curl -fsS -u "$AUTH" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/issue" \
  -d '{"fields":{"project":{"key":"FOO"},"summary":"Title","issuetype":{"name":"Task"}}}'

# Add a comment (ADF body)
curl -fsS -u "$AUTH" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/issue/PROJ-123/comment" \
  -d '{"body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Comment text"}]}]}}'

# List an issue's transitions, then transition it
curl -fsS -u "$AUTH" -H "Accept: application/json" \
  "$BASE/rest/api/3/issue/PROJ-123/transitions"
curl -fsS -u "$AUTH" \
  -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/issue/PROJ-123/transitions" \
  -d '{"transition":{"id":"31"}}'
```

## Confluence (Cloud REST API)

```bash
BASE=https://mirantis.jira.com/wiki
AUTH="$(cat /etc/omp-creds/ATLASSIAN_EMAIL):$(cat /etc/omp-creds/ATLASSIAN_TOKEN)"

# Get a page by ID (add ?expand=body.storage,version for the body + version)
curl -fsS -u "$AUTH" -H "Accept: application/json" \
  "$BASE/rest/api/content/12345?expand=body.storage,version"

# Search pages with CQL
curl -fsS -u "$AUTH" -H "Accept: application/json" \
  "$BASE/rest/api/content/search?cql=space=ENG+AND+title~%22deploy%22"

# Create a page
curl -fsS -u "$AUTH" \
  -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/content" \
  -d '{"type":"page","title":"New Page","space":{"key":"ENG"},
       "body":{"storage":{"value":"<p>Content here</p>","representation":"storage"}}}'

# Update a page (version.number must be current+1)
curl -fsS -u "$AUTH" \
  -H "Content-Type: application/json" \
  -X PUT "$BASE/rest/api/content/12345" \
  -d '{"type":"page","title":"Updated Title","version":{"number":3},
       "body":{"storage":{"value":"<p>Updated content</p>","representation":"storage"}}}'
```

---

## Credential safety

Standard credential handling applies — see the `credential-access` skill and the
always-apply `credential-safety` rule. For these HTTP calls specifically: read the token
from its file with `$(cat …)`, keep it inside the curl command, never echo `$AUTH`, and
never pass `-v`/`--trace`.

## Operations

When you author a JIRA comment/issue or a Confluence page on the user's behalf, end the
body with the AI-attribution line required by the `ai-attribution` rule.
