# Operator Guide

You are an **operator** (a joiner). You've been handed a join link by the
[manager](manager.md) and you want to work in the shared session. There is **no script
to install or run** — you just join.

## 1. Join the session

The manager gives you a link that looks like `n8juTBiv...#...`. From any terminal with
omp installed:

```bash
omp join "n8juTBiv...#..."
```

No omp? Open the browser form instead — paste the same link into `my.omp.sh/#<link>`
and it connects with nothing to install.

You'll drop straight into the live session: the same streaming text, tool-call cards,
footer (cwd, model, context %, cost), and subagent hub everyone else sees. The agent,
repo, and tools all run on the VM — your machine is just a window.

## 2. Work in it

- **Prompt the agent** by typing, same as a local omp session. Your messages are badged
  with your name to other participants; the model sees the text verbatim.
- **Interrupt** a running turn with `Esc`.
- **Watch tools and subagents** live; open the Agent Hub for the host's subagents.

What you **can't** do (these stay with the host): `/model`, `/compact`, `/resume`,
`/branch`, raw bash (`!`), python (`$`), and skills. The host agent executes every tool;
you steer by prompting. If you joined with a **view-only** link, you can read everything
live but can't prompt, interrupt, or control agents.

## 3. The rules you're working under

The session loads the manager's global rules and context automatically, and they apply
to you too. The ones that matter most:

- **Never make the agent print a credential.** Don't ask it to `echo`, `cat`, `printenv`,
  or otherwise reveal a token/key/password value. Credentials are already in the
  environment — the right way to use one is inline in the command that needs it (e.g.
  `curl -H "Authorization: Bearer $GITHUB_TOKEN" ...`). A printed secret is written to
  the session transcript on disk and shown on every participant's screen.
- **Treat the join link as a secret.** Anyone with it can read and (with a full link)
  steer the session. Don't forward it.

If you need to know which credentials exist, ask the agent to list env-var **names**
(not values) — the installed `credential-access` skill explains how.

## Good to know

- **You're inside the trust boundary.** Even though the model only ever receives `#XXXX#`
  placeholders, *you* can see real credential values on screen. Only join sessions
  you're authorised for. (Confining joiners to a session's own credentials is the
  unbuilt Tier-2 work — see
  [the credential-isolation doc](../planning/credential-isolation.md).)
- **The session outlives your connection.** Long operations keep running if you drop
  off; rejoin with the same link. If the host relaunches the session, you'll get a new
  link from the manager.
- **Leaving:** `/leave` (your previous local session, if any, is restored).

For the full picture of how sharing, encryption, and credentials work, see
[the architecture doc](../architecture.md).
