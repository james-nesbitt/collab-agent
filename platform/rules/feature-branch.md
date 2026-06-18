---
description: All work must be done on a feature branch, not directly on the default branch
alwaysApply: true
---

All code changes MUST be committed to a feature branch, never directly to `main`, `master`, or any other default/trunk branch.

- Before starting any work in a git repository, check the current branch with `git branch` or `git status`.
- If you are on a default branch (`main`, `master`, `trunk`, `develop`, etc.), create and switch to a feature branch first.
- Feature branches SHOULD be named after the relevant ticket or issue (e.g. `PRODENG-2469`, `ISSUE-42`). If no ticket exists, use a short descriptive slug (e.g. `fix-lambda-runtime`).
- Do **NOT** commit work to a default branch and move it after the fact. Branch before you commit.
