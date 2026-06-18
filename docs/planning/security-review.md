# Security Review

Review of the remote-agent-machine scripts, docs, and skills for security weaknesses.

- **Scope:** `lib/common.sh`, `administrator.sh`, `manager.sh`, `platform/` assets
  (`RULES.md`, `AGENTS.md`, `secrets.yml`, `credential-access` skill),
  `.omp/skills/{administrator,manager}`, and the docs under `docs/`.
- **Method:** manual audit focused on shell command construction (injection, quoting,
  word-splitting), credential handling (at rest, in transit, in argv/transcript), the
  remote-execution path (`gcloud ssh --command`), supply chain, and the guidance the
  docs/skills give an agent. Automated SAST was attempted (see below).
- **Automated tooling:** the Aikido MCP scan was unavailable in this environment
  (authentication failed — invalid token; configure via the `setup`/Aikido plugin guide
  to enable it). ShellCheck is not installed on the workstation. The manual review
  covers the same quoting/injection classes ShellCheck would flag.

## Summary

| ID | Severity | Title | Status |
| --- | --- | --- | --- |
| F1 | Medium | Session name not validated in `attach`/`kill`/`collab` → remote command injection | **Fixed** |
| F2 | Medium | `valid_token` allows `/` in names → breaks `sed` delimiter, risks local exec | **Fixed** |
| F3 | Low | No-passphrase GPG key; vault dir perms not hardened | Open (Tier-1 accepted) |
| F4 | Low | Supply chain: unpinned `curl \| sh` and global installs in `bootstrap` | Open (recommendation) |
| F5 | Low | Docs don't forbid `-v`/`--trace`/`set -x` with secrets | Open (recommendation) |
| F6 | Info | `collab` shares a write-capable link by default | Open (by design) |
| F7 | Info | `resolve_session` trusts remote tmux output | Covered by F1 fix |

No exposed secrets, hardcoded credentials, or plaintext-at-rest were found. The
credential design (stdin-only `vault-add`, `pass show`-only launcher, `secrets.enabled`
obfuscation) is sound; the findings are mostly input-validation and defense-in-depth.

## Findings

### F1 — Remote command injection via unvalidated session name (Medium) — Fixed

`cmd_new` and the vault commands validate their inputs with `valid_token`, but
`cmd_attach`, `cmd_kill`, and `cmd_collab` interpolated `${name}` straight into remote
command strings executed on the VM through `gcloud ssh --command`:

- `remote "tmux kill-session -t ${name}"`
- `remote_tty "tmux attach -t ${name}"`
- `tmux send-keys -t ${name} … | … grep …` (collab)
- `session_exists` wraps the name in single quotes (`-t '$1'`), but a `'` in the name
  escapes the quoting.

**Impact:** a session name containing shell metacharacters (`;`, `$()`, backticks, `'`)
runs arbitrary commands on the VM as the OS-Login user. The manager who types the name
is trusted, so direct risk is low — but the **default `attach`/`collab` path** derives
the name from `tmux ls` via `resolve_session`, so a session created out-of-band with a
hostile name (another SSH user, or a collab guest who can reach a shell) becomes an
injection vector the manager triggers unknowingly.

**Fix:** added a strict `valid_name` validator and applied it on every name path —
when a name is passed in *and* after `resolve_session` returns one — before the value
reaches any remote command.

### F2 — `valid_token` permits `/`, breaking `sed` and risking local exec (Medium) — Fixed

`valid_token` was `^[A-Za-z0-9_/-]+$` and was used for both vault paths (which need `/`)
and session names. In `cmd_new`:

```sh
sed "s/__SESSION_NAME__/${name}/g" session-template/.omp/AGENTS.md | remote "cat > …"
```

A name containing `/` breaks the `s///` delimiter; a crafted value could terminate the
`s` command and append another sed command. GNU sed's `e` command executes a shell, so
this is a **local** (laptop-side) command-execution risk, plus a `/` in a name yields a
malformed tmux target and session path.

**Fix:** session names now use `valid_name` = `^[A-Za-z0-9_-]+$` (no `/`); the
`/`-allowing `valid_token` is retained only for vault entries and subtrees, which
legitimately need it (`services/github/token`).

### F3 — No-passphrase GPG key; vault directory perms not hardened (Low) — Open

The vault key is generated with `%no-protection` (no passphrase). This is the documented
**Tier-1** boundary: any process running as the omp user — including a collab guest, who
*is* that user — can decrypt every secret. `setup` chmods `GNUPGHOME` to `700` (good:
the private key is protected from other local users), but leaves `~/.omp-vault` and
`~/.omp-vault/store` at the umask default. The `.gpg` ciphertext is useless without the
key, so confidentiality against *other local users* holds as long as `gnupg/` stays
`700`.

**Recommendation:** `chmod 700 ~/.omp-vault` in `setup` for defense-in-depth. The
in-session-guest exposure is the known Tier-1 limitation; the real fix is the Tier-2
per-session OS isolation tracked in [credential-isolation.md](credential-isolation.md).

### F4 — Supply chain: unpinned installs in `bootstrap` (Low) — Open

`administrator.sh bootstrap` runs `curl -fsSL https://mise.run | sh`, then
`mise use -g bun@latest` and `bun install -g @oh-my-pi/pi-coding-agent` — all unpinned.
A compromised upstream installs arbitrary code as the VM user. TLS mitigates MITM, but
there is no version pinning or checksum verification.

**Recommendation:** for a hardened deployment, pin the mise installer to a known version
+ checksum and pin `bun`/`omp` versions. Accepted pattern for a convenience bootstrap;
documented here so it is a conscious choice.

### F5 — Docs don't forbid verbose tooling with secrets (Low) — Open

`RULES.md` and the `credential-access` skill correctly forbid printing secrets and model
inline use (`curl -H "Authorization: Bearer $TOKEN"`), but neither warns that `set -x` /
`bash -x`, or `curl -v` / `--trace`, echo the secret (curl's verbose mode prints request
headers, including `Authorization`). Combined with the documented **R** behavior
(tool output persists de-obfuscated to the session `.jsonl`), this can leak a value the
operator believed was safe.

**Recommendation:** add a line to `RULES.md` / the skill: never use `-v`/`--trace`/
`set -x` (or any header/request-dumping flag) on a command that references a secret.

### F6 — `collab` shares a write-capable link by default (Informational)

`./manager.sh collab NAME` returns the **full** link, which grants prompt/interrupt/
subagent control. For handing a session to many viewers, `view` (read-only) may be the
safer default. Not a code vulnerability — the link is correctly classified as a secret
in `RULES.md` — but worth a conscious choice per engagement.

### F7 — `resolve_session` trusts remote tmux output (Informational)

The most-recently-attached session name returned by `resolve_session` (from `tmux ls`)
was interpolated without validation. This is the escalation path noted in F1 and is now
mitigated: callers validate the resolved name with `valid_name` before use.

## Strengths (verified)

- **Secrets never hit argv:** `vault-add` reads the value from stdin and streams it to
  the remote `pass insert`; it never appears in the process list or shell history.
- **Launcher is R-safe at rest:** the generated `launch.sh` contains only `pass show`
  *commands*, never decrypted values (confirmed on the VM: no sentinel in
  `~/sessions/*/.omp`).
- **Model never sees real values:** `secrets.enabled` obfuscation maps injected
  credentials to `#XXXX#` before any outbound text (verified — the model reported it
  could not read the value).
- **Write-path validation + safe defaults:** `new`/`vault-add`/`vault-ls` validate
  inputs; both scripts run under `set -euo pipefail`; `lib/common.sh` is sourced, never
  executed; `destroy` requires an explicit `yes`.
- **Network posture:** no inbound ports on the VM; SSH control via IAP; collab dials out
  to an E2E-encrypted relay (the key stays in the URL fragment). See
  [the architecture doc](../architecture.md).
- **Agent guidance:** `RULES.md` + the `credential-access` skill enforce a no-print
  discipline and a names-only discovery command (`printenv | sed 's/=.*//' | grep …`).

## Residual risk (by design, tracked)

The dominant exposures are inherent to the current Tier-1 model and are documented, not
code bugs:

- **G** — joined collab guests are inside the credential trust boundary and see real
  values on the de-obfuscated render.
- **R** — a value a tool *prints* persists de-obfuscated to the session transcript.

Both are bounded by `RULES.md` today and closed only by Tier-2 per-session OS isolation
(see [credential-isolation.md](credential-isolation.md)).
