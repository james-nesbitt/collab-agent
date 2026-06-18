# TODO — replace self-reported operator identity with a verified identity mechanism

## Status

Deferred. Today the acting operator is **self-reported**, not verified. This page records
why and the exact change to make once the upstream blocker lands.

## Problem

A shared session can carry several operators' mirantis credentials at once — inject the
`people` subtree and each operator arrives namespaced (`<NS>_ATLASSIAN_*`,
`<NS>_OPERATOR_*`; see `credential-isolation.md`). When a joiner prompts "comment on the
jira ticket", the `mirantis-services` skill must decide **which** operator to act as. It does
so by reading an explicit cue in the prompt ("as alice, …") and, when that is absent or
ambiguous, **challenging** the user to name the operator.

That selection is unauthenticated. The prompter is never verified, so any joined participant
can claim any name, and every injected credential is usable by anyone in the session. This is
credential *selection*, not *isolation* — the same **G** exposure as Tier-1 in
`credential-isolation.md`.

## Blocker

Collab does not surface the prompting joiner's identity to the agent on each prompt: the host
agent receives the prompt text without a trustworthy "who sent this". Tracked upstream as
**oh-my-pi#2975** (open) — <https://github.com/oh-my-pi/oh-my-pi/issues/2975> — whose proposed
solution is to expose the joining user's name to agent context per prompt.

## Target (when #2975 lands)

- Each turn, the agent reads the **harness-provided prompting-user identity** and maps it
  deterministically to that operator's namespace (`<NS>` → `<NS>_ATLASSIAN_*`), selecting
  credentials automatically — **no self-report, no challenge**.
- A prompt cue may only *narrow within* the verified identity (e.g. disambiguate among that
  user's own multiple roles), never override it to act as a different operator.
- Challenge remains only as the fallback when the harness identity is genuinely absent.

Even verified identity is still credential **selection**, not OS-level isolation between
joiners — one joiner can still read another's injected creds in the shared process. Closing
that is the separate Tier-2 work in `credential-isolation.md`.

## Exact change to make then

In `platform/skills/mirantis-services/SKILL.md`, section **"Determine the acting operator"**,
replace step 2's cue/challenge logic with: *use the harness-supplied prompting-user identity
to pick the namespace; challenge only if that identity is absent.* Steps 1 (roster) and 3
(bind `AE_VAR`/`AT_VAR` by namespace) are unchanged. Update the advisory-not-authenticated
caveat to note identity is now harness-verified (still not isolation).
