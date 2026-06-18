---
name: mirantis-services
description: Query and update Mirantis JIRA and Confluence via credentials injected as environment variables. Use when the user asks to read, search, create, or update JIRA issues or Confluence pages.
---

# Mirantis Services (JIRA + Confluence)

JIRA and Confluence share one Atlassian Cloud account. Credentials arrive as
**environment variables** injected at session start from the per-VM vault subtree
`services/` (see the `credential-access` skill). You never fetch them yourself — they
are already in the process environment.

Required vault entries (the operator adds them once with `./manager.sh vault-add`):

| vault entry | env var | value |
|---|---|---|
| `services/atlassian/email` | `ATLASSIAN_EMAIL` | Atlassian account email |
| `services/atlassian/token` | `ATLASSIAN_TOKEN` | Atlassian API token (id.atlassian.com → Security → API tokens) |

If `ATLASSIAN_EMAIL` / `ATLASSIAN_TOKEN` are unset, the operator has not added them
yet — tell the user to run:

```bash
printf '%s' '<email>' | ./manager.sh vault-add services/atlassian/email
printf '%s' '<api-token>' | ./manager.sh vault-add services/atlassian/token
```

then start a new session so the vars are injected.

## Auth pattern — inline only

Reference `$ATLASSIAN_TOKEN` only inside the curl command — the `credential-access` skill
and the always-apply `credential-safety` rule cover why (notably: never `-v`/`--trace`,
which prints the auth header). The base call:

```bash
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" -H "Accept: application/json" <URL>
```

To check a status code without printing headers or body:

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" <URL>
```

## Base URLs

- JIRA: `https://mirantis.jira.com`
- Confluence: `https://mirantis.jira.com/wiki`  <!-- unverified — confirm Confluence base URL; if a request 404s, this is the literal to fix -->

---

## JIRA (REST API v3)

```bash
BASE=https://mirantis.jira.com

# Get an issue
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" -H "Accept: application/json" \
  "$BASE/rest/api/3/issue/PROJ-123"

# Search with JQL
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/search" \
  -d '{"jql":"project=FOO AND status=\"In Progress\"","maxResults":50}'

# Create an issue
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/issue" \
  -d '{"fields":{"project":{"key":"FOO"},"summary":"Title","issuetype":{"name":"Task"}}}'

# Add a comment (ADF body)
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/issue/PROJ-123/comment" \
  -d '{"body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Comment text"}]}]}}'

# List an issue's transitions, then transition it
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" -H "Accept: application/json" \
  "$BASE/rest/api/3/issue/PROJ-123/transitions"
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/issue/PROJ-123/transitions" \
  -d '{"transition":{"id":"31"}}'
```

## Confluence (Cloud REST API)

```bash
BASE=https://mirantis.jira.com/wiki

# Get a page by ID (add ?expand=body.storage,version for the body + version)
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" -H "Accept: application/json" \
  "$BASE/rest/api/content/12345?expand=body.storage,version"

# Search pages with CQL
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" -H "Accept: application/json" \
  "$BASE/rest/api/content/search?cql=space=ENG+AND+title~%22deploy%22"

# Create a page
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/content" \
  -d '{"type":"page","title":"New Page","space":{"key":"ENG"},
       "body":{"storage":{"value":"<p>Content here</p>","representation":"storage"}}}'

# Update a page (version.number must be current+1)
curl -fsS -u "$ATLASSIAN_EMAIL:$ATLASSIAN_TOKEN" \
  -H "Content-Type: application/json" \
  -X PUT "$BASE/rest/api/content/12345" \
  -d '{"type":"page","title":"Updated Title","version":{"number":3},
       "body":{"storage":{"value":"<p>Updated content</p>","representation":"storage"}}}'
```

---

## Credential safety

Standard credential handling applies — see the `credential-access` skill and the
always-apply `credential-safety` rule. For these HTTP calls specifically: keep
`$ATLASSIAN_TOKEN` inside the curl command and never pass `-v`/`--trace`.

## Operations

When you author a JIRA comment/issue or a Confluence page on the user's behalf, end the
body with the AI-attribution line required by the `ai-attribution` rule.
