# Per-session credential isolation

## Status

- **Tier 1 (GSM → ESO → K8s Secret → pod env + global obfuscation)** — DONE.
  - **Injection:** `administrator.sh setup` applies the ESO `ClusterSecretStore omp-gsm`
    (backed by GCP Secret Manager via Workload Identity). `administrator.sh vault-add`
    stores credentials in GSM, labelled `omp_vault=true` and `omp_subtree=<subtree>`.
    At session creation the operator builds an `ExternalSecret` listing the requested
    subtrees; ESO (WI SA `omp-eso`, `secretAccessor`) syncs them into K8s Secret
    `omp-creds` in the session namespace. The pod loads the Secret via `envFrom`. The
    entry path maps to the env var name: strip subtree prefix, replace `/` and `-` with
    `_`, uppercase. Example: `services-github-token` (subtree `services`) → `GITHUB_TOKEN`.
  - **Obfuscation (model):** `secrets.enabled: true` (in the master `omp-config` ConfigMap,
    set by `administrator.sh setup`) replaces matched env-var values with `#XXXX#` before
    any text reaches the model. `platform/secrets.yml` carries value-shape regex backstops.

### Tier 1 findings

- **M = PASS** — the model only ever receives the `#XXXX#` placeholder, never the real
  value.
- **G = guest EXPOSED** — a joined guest sees the real value on the final de-obfuscated
  render and in any tool card. Tier 1 gives **no confidentiality from a session's own
  guests**: joiners are inside the credential trust boundary.
- **R = conditional FAIL** — omp persists `toolResult` blocks de-obfuscated into the
  session `.jsonl`, so a secret leaks to disk **only if a tool prints it**. Mitigated
  operationally by `platform/RULES.md` (never echo/print/log a credential; consume
  it inline).

### Operational conditions for Tier 1 to hold

1. Tools must never echo credential values to stdout (enforced by `RULES.md` + the
   `credential-access` skill).
2. The session-transcript directory needs at-rest protection or redaction, since
   `toolResult` blocks are persisted de-obfuscated.

## Tier 2 — per-session isolation (REALIZED via GKE namespaces)

Goal achieved via the GKE migration (see `docs/planning/gke-migration.md`):

- Each session runs in its own Kubernetes **namespace** (`omp-session-{name}`) with
  its own ServiceAccount, PVC, and K8s Secret — enforced by the API server.
- Credentials are scoped: only the subtrees requested at session creation are synced
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

- Collab/join end-to-end (host on pod, guests join; long ops survive guest disconnect;
  host can change model mid-share; guests use host-context files).
- Tier 1 vault → env injection + obfuscation (this file), now realized via GSM/ESO in
  `administrator.sh` (`setup` / `vault-add`).
