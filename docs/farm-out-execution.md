# Farming out execution to a remote session

A remote session's agent runs **inside its pod, under tmux, independent of any
client connection** — this is already true of the architecture, not something added
for this pattern. Killing your local terminal, harness process, or laptop never
touches the remote tmux session or an in-flight agent turn. This makes it possible
to use a remote session as a place to kick off long-running work from a local
agent/harness, walk away, and collect results later — without holding a local
session or `omp join` connection open for the duration.

This document describes doing that directly with `kubectl exec` + tmux, the same
mechanism the [session operator](../operator/session_operator.py) itself uses to
capture join links (`_tmux_capture_join_link`).

## Prerequisites

- `pods/exec` RBAC on the session's namespace — the same access a manager or team
  member already has (see [manager skill](../skills/manager/SKILL.md),
  [access-control.md](access-control.md)).
- The target session's pod name and namespace:
  `omp-session-<name>` (admin) or `omp-session-<team>-<name>` (team), pod `omp-0`.

## The pattern

**1. Submit a task** (type into the composer, literal-mode to avoid corruption, then
submit):

```bash
NS=omp-session-work
kubectl -n "$NS" exec omp-0 -c omp -- tmux send-keys -t omp Escape
kubectl -n "$NS" exec omp-0 -c omp -- tmux send-keys -t omp C-u
kubectl -n "$NS" exec omp-0 -c omp -- tmux send-keys -t omp -l \
  "Long-running task description here"
kubectl -n "$NS" exec omp-0 -c omp -- tmux send-keys -t omp Enter
```

**2. Detach.** Nothing more to do — the agent turn keeps running in the pod. Close
your terminal, kill your local harness, disconnect entirely.

**3. Reattach and poll** whenever convenient:

```bash
kubectl -n "$NS" exec omp-0 -c omp -- tmux capture-pane -p -t omp | tail -30
```

The status line shows a spinner (`⠹ Working…`) while the turn is active and returns
to the idle prompt (`▶`) when it finishes. There is no clean "done" event to poll for
— this is pane-scraping, not a real API (see [Limitations](#limitations)).

**4. Collect results.** Read the final pane text, or read the session's own
transcript file directly for a structured record instead of scraped terminal output:

```bash
kubectl -n "$NS" exec omp-0 -c omp -- sh -c \
  'tail -c 4000 $(ls -t ~/.omp/agent/sessions/*.jsonl | head -1)'
```

## Rules for using this safely

- **One driver at a time.** A `kubectl exec` script typing into the composer and a
  live collab guest/host typing into the same pane **will corrupt each other's
  input** — this is a real, reproduced failure mode (composer text ending up
  interleaved, e.g. `/collab wss://34.78.117.191.ssli` + `stop` mashed together),
  not a hypothetical. Before driving a session this way, confirm no one is actively
  interacting with it (check `collab:N` in the status line — a live guest count
  means someone may be typing).
- **Always clear the composer first** (`Escape` then `C-u`) and **verify it's empty**
  with a `capture-pane` before typing — a previous half-submitted command or a
  leftover history suggestion can concatenate with what you send.
- **Use `tmux send-keys -l`** (literal mode) for the actual text. Without `-l`, tmux
  interprets some characters as key names and can drop or reorder them — reproduced
  with URLs containing `://`.
- **Wait after `Enter`, don't assume synchronous completion.** A `capture-pane`
  immediately after submitting shows the turn *starting*, not its result. Poll on an
  interval, or accept that this is fire-and-forget with manual check-back.

## Limitations

- **Result extraction is pane-scraping, not a real API.** ANSI-art banners,
  in-progress animation frames, and wrapped long lines all make `capture-pane`
  output unreliable to parse programmatically. Treat it as "good enough for a human
  glancing at status," not as a stable machine-readable contract.
- **No structured "task complete" signal.** You're inferring completion from the
  status line's spinner vs. idle-prompt state, which can be ambiguous during a
  multi-step turn (subagents, tool calls) that finish and start again quickly.

## Planned hardening: RPC mode

omp has a non-interactive RPC mode (`--mode=rpc` / `--mode=rpc-ui`, with bundled
TypeScript and Python clients and a chunked protocol v2 for large payloads) built
for exactly the submit/poll/collect shape this pattern wants, without any pane
scraping. It would replace the fragile parts above with structured requests and
`get_messages_page`-style polling.

**Not yet investigated:** whether an RPC-mode client can safely attach to the *same*
live session the interactive TUI is already running against (concurrent access to
`~/.omp/agent/sessions/*.jsonl`), or whether farming out this way requires a
dedicated non-interactive session distinct from the one a human might also be using
interactively. Until that's resolved, the tmux-exec pattern above is what's
supported.
