---
description: Require explicit user approval before pushing branches or opening PRs
alwaysApply: true
---

Before executing any of the following, you **MUST** pause and obtain explicit user approval:

- `git push` (any remote, any branch)
- `git push --force` / `--force-with-lease`
- Opening a pull request (via `gh pr create`, GitHub MCP tools, or any other mechanism)

Commit locally and stage the work, then stop and ask the user whether to push and open a PR.

Do **NOT** infer approval from plan acceptance, task completion, or instructions to "commit the changes". Push and PR creation are distinct, irreversible external actions.
