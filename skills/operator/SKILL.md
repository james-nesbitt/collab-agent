---
name: operator
description: Act as (or guide) an operator/joiner of a shared omp session — join a collab link, work in the session, and follow the credential/link safety rules. Use when the user asks how to join, what a joiner can or cannot do, view-only links, or the rules a guest works under. For creating/sharing sessions use the `manager` skill; for cluster/platform/vault use the `administrator` skill.
---

# Operator (joiner)

An operator is a **joiner**: handed a collab link by the [`manager`](skill://manager),
they work inside the shared session. There is **no script to install or run** — you just
join. Everything (agent, repo, tools) runs on the session pod; the joiner's machine is
only a window.

Full reference: read `docs/roles/operator.md`.

## Join

```bash
omp join "<link>"        # any terminal with omp installed
```

No omp? Open the browser URL the manager gave you alongside the link (our self-hosted
relay, not `my.omp.sh` — see [docs/relay.md](../../docs/relay.md)) — connects in the
browser, nothing to install. You drop into the live session: same streaming text,
tool-call cards, footer (cwd, model, context %, cost), and subagent hub everyone sees.

## What a joiner can / can't do

| Can | Can't (host-only) |
| --- | --- |
| Prompt the agent (messages badged with your name) | `/model`, `/compact`, `/resume`, `/branch` |
| Interrupt a running turn with `Esc` | Raw bash (`!`) and python (`$`) |
| Watch tools + subagents live (Agent Hub) | Invoke skills |
| Leave with `/leave` (restores your prior local session) | — |

The **host agent executes every tool** — a joiner steers by prompting, not by running
commands. A **view-only** link can read everything live but cannot prompt, interrupt, or
control agents.

## Rules you work under (loaded automatically by the session)

- **Never make the agent print a credential.** Don't ask it to `echo`/`cat`/`printenv` a
  token/key/password. Credentials are delivered as files under `/etc/omp-creds/` — the
  right use is *inline* in the command that needs it (e.g.
  `curl -H "Authorization: Bearer $(cat /etc/omp-creds/GITHUB_TOKEN)" …`).
  A printed secret lands in the on-disk transcript and on every participant's screen. To
  see what exists, ask for credential **names** only (`ls /etc/omp-creds/`; the
  `credential-access` skill explains).
- **Treat the join link as a secret.** Anyone with a full link can read *and steer* the
  session; a view link can read. Don't forward it.

## Good to know

- **You're inside the trust boundary.** The model only ever receives `#XXXX#` placeholders,
  but *you* see real credential values on tool cards — only join sessions you're authorised
  for. Each session is an isolated K8s namespace with only its own credentials; other
  sessions' pods are unreachable (NetworkPolicy).
- **The session outlives your connection.** Long operations keep running if you drop off;
  rejoin with the same link. The pod restarts automatically if it exits, and the manager
  will have a fresh join link after a restart (the link rotates on restart).

For how sharing, encryption, and credential isolation work end to end, see
`docs/architecture.md`.

## Session pod naming (Option C / StatefulSet)

When the platform is running Option C (StatefulSet sessions), the session pod is named
**`omp-0`** (StatefulSet ordinal), not `omp`. This affects any `kubectl exec` or
`kubectl logs` command targeting the session pod directly:

```bash
# StatefulSet pod name
kubectl exec -it -n omp-session-NAME omp-0 -- bash
kubectl logs -n omp-session-NAME omp-0

# (Legacy bare-pod name — pre-Option-C)
# kubectl exec -it -n omp-session-NAME omp -- bash
```

As a joiner this is transparent — you connect via the collab link regardless. It matters
only if an admin or manager needs to exec directly into the pod for debugging.
