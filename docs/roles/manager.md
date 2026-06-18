# Manager Guide

You are the **manager**. You own omp on the VM: you configure the platform once, you
hold the credentials, and you create and share the sessions people actually work in.
You assume the [administrator](administrator.md) has already provisioned and
bootstrapped the VM.

Everything you do goes through **`manager.sh`**, run from this repo on your laptop. It
drives the VM over `gcloud ssh` + IAP — including the interactive omp TUI, which it
steers with `tmux send-keys` / `capture-pane`.

## Before you start

- The administrator has run `./administrator.sh provision` and `bootstrap`, and the VM
  is running (`./administrator.sh status` shows `RUNNING`).
- That's it — you don't need anything installed beyond `gcloud`.

## 1. First time: configure the platform

```bash
./manager.sh setup
```

One idempotent command does three things:

1. Turns on global secret obfuscation (`secrets.enabled`) so credential values are
   replaced with `#XXXX#` before any text reaches the model.
2. Ensures the credential vault exists at `~/.omp-vault` on the VM (a no-passphrase
   `pass` store).
3. Installs the global rules, context, and the credential-access skill into
   `~/.omp/agent/` so every session inherits them.

You'll see `SETUP_OK` and the four installed asset paths. Re-run it any time you change
the files under `platform/` — it just overwrites them.

## 2. Store the credentials people will need

Credentials live in the vault under a subtree (default `services`). Add one by piping
the value in on **stdin** — never as an argument, so it never lands in your shell
history or the process list:

```bash
printf '%s' "$MY_GITHUB_TOKEN" | ./manager.sh vault-add services/github/token
```

Check what's there (names only, never values):

```bash
./manager.sh vault-ls services
```

**Naming matters.** The entry path becomes an environment variable name: `/` and `-`
become `_`, uppercased. So `services/github/token` → `GITHUB_TOKEN`, which matches
omp's `TOKEN` pattern and is auto-obfuscated. End an entry with a secret keyword
(`token`, `key`, `secret`, `password`) so this fires. If you must use a name that
doesn't, add a value-shape regex to `platform/secrets.yml` and re-run `setup`, or the
value won't be obfuscated.

## 3. Launch a session

```bash
./manager.sh new work
```

This creates a detached tmux session named `work` running omp, with a seeded
`~/sessions/work/.omp/` and the whole `services` subtree injected as env vars. Want a
different subtree? `./manager.sh new work --subtree clients/acme`.

You'll see it confirm the session is running and remind you how to attach and share.

## 4. Share it

```bash
./manager.sh collab work
```

This sends `/collab` into the session and prints the join link:

```
omp join "n8juTBiv...QPNqAGqaEPeSf..."
```

Hand that to your operators (see the [operator guide](operator.md)). For a read-only
link, `./manager.sh collab work view`.

## 5. Drive, list, end

```bash
./manager.sh attach work     # take the keyboard yourself (most recent if NAME omitted)
./manager.sh list            # what's running
./manager.sh kill work       # end the session
```

To swap in new per-session skills: drop them into `~/sessions/work/.omp/skills/` and
restart the session (`kill` then `new` — the folder persists). Skills are discovered at
session startup, not hot-reloaded.

## The one rule you must internalize

The model never sees real credential values, but **everyone in the session does**, and
**any value a tool prints gets written to the session transcript on disk**. That's why
the installed `RULES.md` forbids printing secrets, and why a joined guest is inside the
credential trust boundary. If you store a credential someone shouldn't see, don't share
that session with them — there is no per-joiner credential hiding yet (that's the
Tier-2 roadmap). Full reasoning:
[the credential-isolation doc](../planning/credential-isolation.md).

## Troubleshooting

- **`collab` prints "No join link found" + a full pane dump.** The session was launched
  in a pane too narrow for omp to print the link on one line. Sessions created by `new`
  use a wide pane, so recreate with `kill` + `new` if you hit this on an old session.
- **Launcher exported nothing / a var is missing.** Check the subtree has entries:
  `./manager.sh vault-ls services`. Empty subtree → `new` warns and the session still
  launches, just without injected creds.
- **A value isn't obfuscated.** Its env-var name probably lacks a secret keyword — add
  a regex to `platform/secrets.yml`, re-run `setup`, relaunch the session.

## What you don't do

You never provision, start/stop, or destroy the VM — that's the
[administrator](administrator.md). And operators never run a script; they just join the
link you give them.
