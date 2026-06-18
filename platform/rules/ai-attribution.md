---
description: Content authored or updated by an AI agent on the user's behalf must declare the model used
alwaysApply: true
---

Any content you create or update on the user's behalf in an external system or a shared
document MUST end with an attribution line identifying the AI agent that authored it.

This applies to:
- **JIRA** — issue descriptions and comments.
- **Confluence** — page bodies you create or update.
- **GitHub** — issue bodies, issue comments, PR bodies, and PR review comments.
- **General docs** — any document, wiki page, or shared note you create or materially
  update on the user's behalf.

Format:
- `Written by AI: <model-name>` — use the model name from your own identity (e.g.
  `claude-sonnet-4-6`, `gpt-4o`, `gemini-2.5-pro`).
- Place it as the final line, separated from the main content by a blank line. For
  ADF/structured bodies (JIRA), append it as the final paragraph node instead.

It does NOT apply to non-free-text field updates — status transitions, assignee or label
changes, reactions, or similar metadata — nor to source code.
