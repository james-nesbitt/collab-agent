---
name: github
description: Interact with GitHub (repos, PRs, issues, comments) via the gh CLI and git, using per-operator tokens injected as environment variables. Use when the user asks to open, review, comment on, or merge a PR or issue, or push a branch.
---

# GitHub

GitHub work uses a per-operator personal access token (PAT) injected as an **environment
variable** at session start from the per-VM `pass` vault (see the `credential-access` skill).
You never fetch it yourself — it is already in the process environment, and you must never
print it.

## Credential model

Like the `atlassian` and `operator` credentials, each operator's GitHub PAT is a **single**
multi-line `pass` entry at `people/<operator>/github` with a `token:` line. The structured
`<ENTRY>_<KEY>` mapping turns that into a `…_GITHUB_TOKEN` var — which matters: only a name
ending in `TOKEN` auto-obfuscates.

| vault entry | lines | injects as | when |
|---|---|---|---|
| `people/<op>/github` | `token: …` | `<NS>_GITHUB_TOKEN` (e.g. `JNESBITT_GITHUB_TOKEN`) | `--subtree people` (multi-operator) |
| `people/<op>/github` | `token: …` | `GITHUB_TOKEN` (bare) | `--subtree people/<op>` (single-operator) |
| `services/github/token` | (single value) | `GITHUB_TOKEN` | `--subtree services` (shared, non-personal) |

An operator creates theirs once (value streamed on stdin, never echoed):

```bash
printf 'token: %s\n' '<github-pat>' | ./manager.sh vault-add people/alice/github
```

`GITHUB_TOKEN` matches omp's `TOKEN` secret-name pattern, so it auto-obfuscates — you pass it
inline but never see the value. If no `*_GITHUB_TOKEN` is present, no operator has added a PAT;
tell the user to add the entry above and start a new session so it is injected.

## Determine the acting operator

Do this **before any authenticated GitHub call** — read or write (push, PR/issue create,
comment, merge, review). This session may carry several operators' tokens at once, and collab
does not tell you which joined user sent a prompt (oh-my-pi#2975), so you MUST establish the
actor explicitly — never guess, never default silently. This mirrors the `mirantis-services`
skill; if you already resolved an operator this turn, reuse it.

1. **Build the roster (names only — never tokens):**

   ```bash
   printenv | sed 's/=.*//' | grep -E '_OPERATOR_NAME$|^OPERATOR_NAME$'
   ```

   Each `<NS>_OPERATOR_NAME` is one operator (display name = its value; GitHub token =
   `<NS>_GITHUB_TOKEN`). A bare `OPERATOR_NAME` means a single-operator session (token = bare
   `GITHUB_TOKEN`). Operator names/emails are not secret and may be shown; tokens never.

2. **Choose the actor.**
   - Exactly one operator with a GitHub token → use it.
   - The prompt names one ("as alice, open the PR", "comment as Bob") matching a roster entry →
     use that one.
   - Otherwise (several operators, no clear cue) → **STOP and challenge**: *"I can act as: Alice
     (alice@…), Bob (bob@…). Who should I act as on GitHub?"* and wait.
   - If the harness later supplies the prompting user's identity directly, prefer it over
     challenging.

3. **Bind the chosen operator's token variable NAME (not the value):**

   ```bash
   NS=JNESBITT   # or empty for a bare single-operator session
   GT_VAR="${NS:+${NS}_}GITHUB_TOKEN"
   ON_VAR="${NS:+${NS}_}OPERATOR_NAME"
   ```

   Pass the token to `gh`/`git` only as `GH_TOKEN="${!GT_VAR}"` on the command itself (see
   below); never echo it, never `-v`/`--trace`.

This selects which credential to **act with**. It is **advisory and unauthenticated**: any
joined participant can claim any name, and all joiners share the env and screen. It is
credential *selection*, not *isolation* — do not treat it as authentication.

## Auth pattern — inline only

`gh` reads `GH_TOKEN` from the environment; supply the resolved operator's token inline so the
value never persists or prints:

```bash
# Who is this token? (sanity check — not an identity source)
GH_TOKEN="${!GT_VAR}" gh auth status 2>&1 | head -5
```

For `git` over HTTPS, configure gh as the credential helper for the command, again inline:

```bash
GH_TOKEN="${!GT_VAR}" gh auth setup-git    # writes a credential helper using GH_TOKEN
GH_TOKEN="${!GT_VAR}" git push origin HEAD
```

Never embed the token in a remote URL you might print, and never run `gh`/`git` under `-v`.

## Common operations (gh)

```bash
# View / list
GH_TOKEN="${!GT_VAR}" gh pr view 42 --json title,state,author
GH_TOKEN="${!GT_VAR}" gh pr list --repo owner/repo --state open
GH_TOKEN="${!GT_VAR}" gh issue view 7 --json title,state,body

# Create a PR (body MUST end with the AI-attribution line — see below)
GH_TOKEN="${!GT_VAR}" gh pr create --title "TITLE" --body "$(cat <<'EOF'
<body>

Written by AI: <model-name>
EOF
)"

# Comment on a PR / issue
GH_TOKEN="${!GT_VAR}" gh pr comment 42 --body "$(printf '%s\n\nWritten by AI: <model-name>\n' 'Comment text')"
GH_TOKEN="${!GT_VAR}" gh issue comment 7 --body "..."

# Create an issue / merge a PR
GH_TOKEN="${!GT_VAR}" gh issue create --title "TITLE" --body "..."
GH_TOKEN="${!GT_VAR}" gh pr merge 42 --squash
```

The REST API via `curl` is an alternative when `gh` lacks a verb:
`curl -fsS -H "Authorization: Bearer ${!GT_VAR}" -H "Accept: application/vnd.github+json" https://api.github.com/...`
(no `-v`; use `-o /dev/null -w '%{http_code}'` to probe status without printing headers).

## Push / PR approval

The always-apply `git-push-approval` rule still governs: never `git push`, force-push, or open
a PR without explicit user approval in the conversation. Resolve the actor and stage the work,
then ask before the push/PR.

## Attribution

Every PR body, issue body, PR/issue comment, and PR review you author MUST end with the line
required by the `ai-attribution` rule:

```
Written by AI: <model-name>
```

(use your own model id). State who you are acting as — "Acting as `${!ON_VAR}`" — when you
author GitHub content, the same as `mirantis-services`.

## Credential safety

Standard handling applies — see the `credential-access` skill and the always-apply
`credential-safety` rule. For GitHub specifically: pass the token only as `GH_TOKEN="${!GT_VAR}"`
on the command, never echo it, never put it in a printed URL, never run `gh`/`git`/`curl` with
`-v`/`--trace`.
