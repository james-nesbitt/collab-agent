---
name: mirantis-services
description: Query and update Mirantis JIRA and Confluence via credentials injected as environment variables. Use when the user asks to read, search, create, or update JIRA issues or Confluence pages.
---

# Mirantis Services (JIRA + Confluence)

JIRA and Confluence share one Atlassian Cloud account **per operator**. Credentials arrive
as **environment variables** injected at session start from the per-VM `pass` vault (see the
`credential-access` skill). You never fetch them yourself — they are already in the process
environment.

## Credential model

Each operator has two structured (multi-line) vault entries under `people/<operator>/`:

| vault entry | lines | injects as |
|---|---|---|
| `people/<op>/operator` | `name: …` / `email: …` | `OPERATOR_NAME` / `OPERATOR_EMAIL` (identity; not secret) |
| `people/<op>/atlassian` | `email: …` / `token: …` | `ATLASSIAN_EMAIL` / `ATLASSIAN_TOKEN` (credential) |

How they land in the environment depends on which subtree the session injected:

- `./manager.sh new team --subtree services --subtree people` — **multi-operator**: every
  operator's vars arrive **namespaced** by the operator's directory name, e.g.
  `ALICE_ATLASSIAN_EMAIL` / `ALICE_ATLASSIAN_TOKEN` / `ALICE_OPERATOR_NAME` /
  `ALICE_OPERATOR_EMAIL`, `BOB_…`.
- `./manager.sh new alice --subtree services --subtree people/alice` — **single-operator**:
  the same vars arrive **bare** (`ATLASSIAN_EMAIL`, `ATLASSIAN_TOKEN`, `OPERATOR_NAME`,
  `OPERATOR_EMAIL`).

An operator creates their entries once with `./manager.sh vault-add` (value streamed on
stdin, never echoed):

```bash
printf 'name: Alice Example\nemail: alice@mirantis.com\n'      | ./manager.sh vault-add people/alice/operator
printf 'email: alice@mirantis.com\ntoken: <alice-api-token>\n' | ./manager.sh vault-add people/alice/atlassian
```

(API token: id.atlassian.com → Security → API tokens.) If no `*_ATLASSIAN_TOKEN` (or bare
`ATLASSIAN_TOKEN`) is present, no operator has added theirs yet — tell the user to add the
entries above and start a new session so the vars are injected.

## Determine the acting operator

Do this **before any JIRA/Confluence call — read or write**: every call needs an Atlassian
token, and in a multi-operator session that means choosing *whose*. This session may carry
several operators' identities at once, and collab does not tell you which joined user sent a
prompt (oh-my-pi#2975), so you MUST establish the actor explicitly — never guess, never
default silently. State the operator you resolved to (e.g. "Acting as James Nesbitt") before
the first call so the choice is visible.

1. **Build the roster (names only — never tokens).** Operator names and emails are not secret
   and may be shown; tokens never.

   ```bash
   printenv | sed 's/=.*//' | grep -E '_OPERATOR_NAME$|^OPERATOR_NAME$'
   ```

   Each `<NS>_OPERATOR_NAME` is one operator (display name = its value; creds =
   `<NS>_ATLASSIAN_EMAIL` / `<NS>_ATLASSIAN_TOKEN`). A bare `OPERATOR_NAME` (no prefix) means
   a single-operator session (creds = bare `ATLASSIAN_EMAIL` / `ATLASSIAN_TOKEN`).

2. **Choose the actor.** The actor may come ONLY from: an explicit operator named in the
   prompt, a harness-supplied prompting-user identity, or the user's answer to a challenge.
   - **NEVER infer the operator from ambient signals** — not the Linux/OS username, not
     `$HOME`, not the session directory or cwd (e.g. `/home/jnesbitt_…/sessions/…`), not git
     config, not any environment artifact. The session home always belongs to the VM's single
     OS user and tells you NOTHING about which operator is prompting. Treating it as a cue is
     the exact unauthenticated guess this step exists to prevent.
   - Exactly one operator in the roster → use it (the only case with no ambiguity).
   - The prompt explicitly names one ("as alice, comment…", "comment as Bob") matching a
     roster entry → use that one.
   - Two or more operators and the prompt does not explicitly name one → **STOP and
     challenge**, even if the environment seems to "suggest" someone: *"This session carries
     several identities — I can act as: Alice (alice@…), James Nesbitt (jnesbitt@…). Who should
     I act as?"* Wait for the answer; make no JIRA/Confluence call until you have it.
   - If the harness supplies the prompting user's identity directly, use it instead of
     challenging.

3. **Bind the chosen operator's credential variable NAMES (not values).** Let `NS` be the
   chosen namespace (e.g. `ALICE`), or empty in a bare single-operator session:

   ```bash
   NS=ALICE   # or:  NS=
   AE_VAR="${NS:+${NS}_}ATLASSIAN_EMAIL"
   AT_VAR="${NS:+${NS}_}ATLASSIAN_TOKEN"
   ON_VAR="${NS:+${NS}_}OPERATOR_NAME"
   ```

   Use `"${!AE_VAR}:${!AT_VAR}"` as the curl credential in **every** call below; never echo
   either, never `-v`/`--trace`.

This selects which credential to **act with**. It is **advisory and unauthenticated**: any
joined participant can claim any name, and all joiners share the env and screen. It is
credential *selection*, not *isolation* — do not treat it as authentication.

## Auth pattern — inline only

Reference the token only inside the curl command — the `credential-access` skill and the
always-apply `credential-safety` rule cover why (notably: never `-v`/`--trace`, which prints
the auth header). The base call:

```bash
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" -H "Accept: application/json" <URL>
```

To check a status code without printing headers or body:

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' -u "${!AE_VAR}:${!AT_VAR}" <URL>
```

Optional connectivity check (does this token authenticate? — **not** an identity source):

```bash
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" -H "Accept: application/json" \
  "https://mirantis.jira.com/rest/api/3/myself"
```

If its `emailAddress` disagrees with the chosen operator's `${NS:+${NS}_}OPERATOR_EMAIL`, the
wrong creds were bound — re-resolve the actor.

## Base URLs

- JIRA: `https://mirantis.jira.com`
- Confluence: `https://mirantis.jira.com/wiki`  <!-- unverified — confirm Confluence base URL; if a request 404s, this is the literal to fix -->

---

## JIRA (REST API v3)

```bash
BASE=https://mirantis.jira.com

# Get an issue
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" -H "Accept: application/json" \
  "$BASE/rest/api/3/issue/PROJ-123"

# Search with JQL
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/search" \
  -d '{"jql":"project=FOO AND status=\"In Progress\"","maxResults":50}'

# Create an issue
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/issue" \
  -d '{"fields":{"project":{"key":"FOO"},"summary":"Title","issuetype":{"name":"Task"}}}'

# Add a comment (ADF body)
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/issue/PROJ-123/comment" \
  -d '{"body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Comment text"}]}]}}'

# List an issue's transitions, then transition it
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" -H "Accept: application/json" \
  "$BASE/rest/api/3/issue/PROJ-123/transitions"
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" \
  -H "Content-Type: application/json" \
  -X POST "$BASE/rest/api/3/issue/PROJ-123/transitions" \
  -d '{"transition":{"id":"31"}}'
```

## Confluence (Cloud REST API)

### Default space

**Always use `PRODENG` as the default Confluence space** unless the user explicitly specifies otherwise.
- PRODENG space key: `PRODENG`
- PRODENG homepage ID: `1901003000`
- PRODENG space URL: `https://mirantis.jira.com/wiki/spaces/PRODENG`

When creating a page without an explicit parent, use the PRODENG homepage as the ancestor:
```json
{"ancestors": [{"id": "1901003000"}]}
```

### Known behaviours and constraints

- **For POST/PUT with a body**, always write the payload to a temp file and pass `--data-binary @/tmp/file.json`. Inline `-d '{...}'` with complex JSON is unreliable.
- **`text~` CQL search does not work** on this instance — use title-based or direct ID lookups instead.
- **Cannot move pages between spaces** without space admin rights — create in the correct space from the start.
- **Cannot delete pages** without space admin rights — if a page lands in the wrong place, update its title to `[DELETE] ...`, set the body to a redirect note pointing at the correct page, and ask the user to manually trash it.
- **Page creation response may return `space: null`** even on success — confirm by fetching the page by ID.
- **Version number for updates must be `current + 1`** — always fetch the current version before a PUT.
- **Special Unicode characters in titles** (em dashes, emoji) can cause 400 errors — use ASCII hyphens in page titles.

```bash
BASE=https://mirantis.jira.com/wiki

# Get a page by ID (add ?expand=body.storage,version for the body + version)
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" -H "Accept: application/json" \
  "$BASE/rest/api/content/12345?expand=body.storage,version"

# Get space homepage ID
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" -H "Accept: application/json" \
  "$BASE/rest/api/space/PRODENG?expand=homepage"

# List pages in a space
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" -H "Accept: application/json" \
  "$BASE/rest/api/content?spaceKey=PRODENG&type=page&limit=25"

# Create a page (write payload to file — do NOT use inline -d for complex JSON)
cat > /tmp/page.json << 'EOF'
{
  "type": "page",
  "title": "New Page",
  "space": {"key": "PRODENG"},
  "ancestors": [{"id": "1901003000"}],
  "body": {"storage": {"value": "<p>Content here</p>", "representation": "storage"}}
}
EOF
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -X POST "$BASE/rest/api/content" --data-binary @/tmp/page.json

# Update a page (version.number must be current+1)
cat > /tmp/update.json << 'EOF'
{
  "type": "page",
  "title": "Updated Title",
  "version": {"number": 3},
  "body": {"storage": {"value": "<p>Updated content</p>", "representation": "storage"}}
}
EOF
curl -fsS -u "${!AE_VAR}:${!AT_VAR}" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -X PUT "$BASE/rest/api/content/12345" --data-binary @/tmp/update.json
```

---

## Credential safety

Standard credential handling applies — see the `credential-access` skill and the always-apply
`credential-safety` rule. For these HTTP calls specifically: keep the token inside the curl
command (via `${!AT_VAR}`) and never pass `-v`/`--trace`.

## Operations

When you author a JIRA comment/issue or a Confluence page on the user's behalf, state who you
are acting as — "Acting as `${!ON_VAR}`" — and end the body with the AI-attribution line
required by the `ai-attribution` rule.
