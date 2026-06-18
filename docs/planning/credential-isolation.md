# TODO — per-session credential isolation

## Status

- **Tier 1 (vault → env injection + global obfuscation)** — DONE, wired into
  `manager.sh`. This is the selected design ("Approach A"); the earlier
  `pass`-store-plus-wrappers sketch is dropped.
  - **Injection:** `manager.sh setup` keeps a no-passphrase ed25519 `pass` vault at
    `~/.omp-vault` on the VM and enables global `secrets.enabled`. `manager.sh new`
    generates a per-session launcher that decrypts one or more subtrees (`--subtree`
    repeats, default `services`; a later subtree wins on a name collision) and exports
    each entry as an env var, then `exec omp`. The entry path maps to the var name (`/`
    and `-` → `_`, uppercased), e.g. `services/github/token` → `GITHUB_TOKEN`; a
    multi-line `key: value` entry expands to one `<ENTRY>_<KEY>` var per line, so
    injecting the `people` subtree namespaces each operator (`people/alice/atlassian` →
    `ALICE_ATLASSIAN_*`). The launcher holds only `pass show` commands — never values.
  - **In-session multi-operator identity (advisory selection, not isolation):** a session
    can inject several operators' credentials at once (inject the `people` subtree → each
    operator namespaced as `<NS>_ATLASSIAN_*` / `<NS>_OPERATOR_*`). Because collab does not
    expose which joined user sent a prompt (oh-my-pi#2975, open), the `mirantis-services`
    skill resolves the acting operator from an explicit prompt cue and challenges the user
    when it is ambiguous. This selects which credential to act with; it does **not** isolate
    one operator's creds from another joiner — any joiner can claim any identity and every
    injected credential is usable by anyone in the session (the same **G** boundary as
    Tier-1). Replacing this self-reported selection with a verified identity is the
    `operator-identity.md` TODO.
  - **Obfuscation (model):** `secrets.enabled` replaces matched env-var values with
    `#XXXX#` placeholders before outbound text reaches the model.
    `~/.omp/agent/secrets.yml` carries value-shape regex backstops for any var whose
    name lacks a secret keyword.
  - **Optional passphrase (at-rest hardening):** `manager.sh setup --passphrase`
    instead creates a passphrase-protected vault key. The passphrase is read locally
    (never argv/disk) and, at session start, `manager.sh new` presets it into the VM's
    `gpg-agent` over SSH on stdin just before launch, so the detached launcher decrypts
    with `pass show` and no pinentry prompt; it lives only in agent memory (bounded by
    `max-cache-ttl`). This protects the vault against disk theft / other local users.
    It does **not** change the G/R in-session exposure below — once the launcher
    exports secrets into the omp process env, an in-session guest (the same OS user)
    can read them regardless. That gap is Tier 2.

### POC findings (verbatim)

- **M = PASS** — the model only ever receives the `#XXXX#` placeholder, never the real
  value.
- **G = guest EXPOSED** — a joined guest sees the real value on the final de-obfuscated
  render and in any tool card. Tier 1 gives **no confidentiality from a session's own
  guests**: joiners are inside the credential trust boundary.
- **R = conditional FAIL** — omp persists `toolResult` blocks de-obfuscated into the
  session `.jsonl`, so a secret leaks to disk **only if a tool prints it**. Mitigated
  operationally by `~/.omp/agent/RULES.md` (never echo/print/log a credential; consume
  it inline), not by isolation.

### Operational conditions for Tier 1 to hold

1. Tools must never echo credential values to stdout (enforced by `RULES.md` + the
   `credential-access` skill).
2. The session-transcript directory needs at-rest protection or redaction, since
   `toolResult` blocks are persisted de-obfuscated.

## Tier 2 — per-session OS-level isolation (NOT YET DONE)

Goal: real isolation so a session's guests are confined to that session's credential
identity, and one session cannot read another's secrets. Justified directly by the
**G** result (guests currently see real values) and the **R** caveat (transcript leaks
when a tool prints a value); both are confidentiality gaps Tier 1 cannot close.

Design sketch:
- Each collab session runs `omp` as its **own Linux user** (or container / user
  namespace) with its own `$HOME`, vault, and GPG key.
- Cross-session isolation enforced by filesystem permissions / namespaces — a guest's
  `cat`/`gpg -d` cannot reach a sibling session's store.
- Requires a **privileged provisioner** (runs as root or via sudo) that, at session
  creation: creates/min-provisions the user (or spins a container), seeds only the
  needed credential subset into that user's store, and launches `omp` as that user
  inside tmux.
- `manager.sh new NAME` grows an `--as-user` / `--isolated` mode that calls the
  provisioner instead of launching in the shared home.
- Open questions to resolve in the Tier 2 POC:
  - User-per-session vs container-per-session (cleanup, image size, GPU/tooling).
  - How the operator seeds the per-user GPG key without exposing it to the shared host
    (sealed transfer, or per-user key generated in-place).
  - Lifecycle: teardown of the user/container + store when the session ends.
  - Whether to gate the model credential the same way (per-user `omp auth`).

## Related POCs already done

- Collab/join end-to-end (host on VM, guests join; long ops survive guest disconnect;
  host can change model mid-share; guests use host-context files).
- Tier 1 vault → env injection + obfuscation (this file), now formalized in
  `manager.sh` (`setup` / `vault-add` / `new`).
