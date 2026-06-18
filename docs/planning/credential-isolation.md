# TODO — per-session credential isolation

## Status

- **Tier 1 (vault → env injection + global obfuscation)** — DONE, wired into
  `manager.sh`. This is the selected design ("Approach A"); the earlier
  `pass`-store-plus-wrappers sketch is dropped.
  - **Injection:** `manager.sh setup` keeps a no-passphrase ed25519 `pass` vault at
    `~/.omp-vault` on the VM and enables global `secrets.enabled`. `manager.sh new`
    generates a per-session launcher that decrypts the configured subtree (default
    `services`) and exports each entry as an env var, then `exec omp`. The entry path
    maps to the var name (`/` and `-` → `_`, uppercased), e.g.
    `services/github/token` → `GITHUB_TOKEN`. The launcher holds only `pass show`
    commands — never values.
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

## Tier 2 — per-session isolation (REALIZED via GKE namespaces)

Goal achieved via the GKE migration (see `docs/planning/gke-migration.md`):

- Each session runs in its own Kubernetes **namespace** (`omp-session-{name}`) with
  its own ServiceAccount, PVC, and K8s Secret — enforced by the API server.
- Credentials are scoped: only the subtrees requested at `manager.sh new` are synced
  into that session's ExternalSecret/Secret. The operator calls `list_secrets` only
  (metadata); ESO holds the `secretAccessor` role and never exposes values to the
  operator process.
- **NetworkPolicy** `deny-all` + `allow-egress-https` (except RFC1918 and
  `169.254.169.254/32`) enforces that a pod cannot reach sibling session namespaces or
  the GCE metadata server.
- The remaining gap: **joined guests still see all of that session's injected creds**
  on the collab render (G = guest EXPOSED is unchanged). Per-joiner hiding within a
  shared session would require a second relay tier or client-side filtering — not built.

## Related POCs already done

- Collab/join end-to-end (host on VM, guests join; long ops survive guest disconnect;
  host can change model mid-share; guests use host-context files).
- Tier 1 vault → env injection + obfuscation (this file), now formalized in
  `manager.sh` (`setup` / `vault-add` / `new`).
