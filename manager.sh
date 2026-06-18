#!/usr/bin/env bash
# manager.sh — manager role: omp platform configuration + tmux session lifecycle
# on the omp-agent VM.
#
# Usage:
#   ./manager.sh <subcommand> [args...]
#
# Platform config (global, idempotent):
#   setup [--passphrase]     Enable secret obfuscation, ensure the credential
#                            vault, and install global rules, commands, skills,
#                            secret patterns, and portable tuning (incl. modelRoles).
#                            --passphrase: protect the vault key with a passphrase
#                            (prompted; injected at session start, never stored).
#   vault-add ENTRY          Insert a vault entry (value read from stdin, never
#                            echoed), e.g.  printf '%s' "$TOK" | ./manager.sh \
#                            vault-add services/github/token
#   vault-ls [SUBTREE]       List vault entry NAMES only (no values).
#   tune [--memory] [--thinking]
#                            Apply opt-in local-model tuning: mnemopi long-term
#                            memory (--memory) and/or automatic thinking-level
#                            selection (--thinking). Local ONNX models, no Ollama.
#                            No flag applies both.
#
# Session lifecycle:
#   new NAME [--subtree SUB]...
#                            Create a detached tmux session running omp, with a
#                            seeded per-folder .omp/ and one or more vault subtrees
#                            (default: services) injected as env vars. --subtree is
#                            repeatable; subtrees merge, later wins. A multi-line
#                            'key: value' entry injects as <ENTRY>_<KEY>; injecting
#                            'people' gives per-operator namespaced vars (e.g.
#                            ALICE_ATLASSIAN_TOKEN, ALICE_OPERATOR_NAME).
#   attach [NAME] | a        Attach to a session (most recent if NAME omitted).
#   list | ls                List tmux sessions on the VM.
#   kill NAME                Kill a tmux session.
#   collab [NAME] [view]     Share the session and print its omp join link.
#   help                     Show this help
#
# For VM lifecycle (provision/start/stop/bootstrap/destroy), see ./administrator.sh.
#
# Configuration (override via environment):
#   INSTANCE_NAME    (default: omp-agent)
#   ZONE             (default: europe-west1-b)
#   USE_IAP          (default: true) — tunnel SSH through IAP
#   SUBTREE          (default: services) — vault subtree injected by 'new'
set -euo pipefail

# ---------------------------------------------------------------------------
# Shared config + helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="manager"
[[ -f "${SCRIPT_DIR}/lib/common.sh" ]] || { echo "[manager] ERROR: lib/common.sh not found" >&2; exit 1; }
. "${SCRIPT_DIR}/lib/common.sh"

# Default vault subtree injected as env vars by 'new'. The credential vault lives
# at $HOME/.omp-vault on the VM (sessions root: $HOME/sessions) — both expand
# remotely, so they are fixed rather than plumbed from the laptop.
SUBTREE="${SUBTREE:-services}"

# ---------------------------------------------------------------------------
# Manager-specific helpers
# ---------------------------------------------------------------------------
# Return 0 if a tmux session named $1 exists on the remote.
session_exists() {
    remote "tmux has-session -t '$1' 2>/dev/null"
}

# Resolve a session name: echo $1, or the most-recently-attached session.
resolve_session() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        name=$(remote "tmux ls -F '#{session_last_attached} #{session_name}' 2>/dev/null \
                       | sort -rn | head -1 | awk '{print \$2}'" \
                       2>/dev/null | tr -d '[:space:]')
        [[ -n "${name}" ]] || die "No tmux sessions on the VM. Run: ./manager.sh new NAME"
    fi
    echo "${name}"
}

# upload <local-src> <remote-dest>  — stream a repo file to the VM; dest may use ~.
upload() {
    local src=$1 dest=$2
    [[ -f "${src}" ]] || die "asset missing: ${src}"
    remote "cat > ${dest}" < "${src}"
}

# Validate a session/subtree token (no shell metacharacters → safe to interpolate).
valid_token() { [[ "$1" =~ ^[A-Za-z0-9_/-]+$ ]]; }
# Validate a session name (stricter than valid_token: no '/', so it is safe to
# interpolate into remote tmux -t targets, filesystem paths, and the sed delimiter).
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

# Create/ensure a passphrase-protected vault on the VM. Takes the passphrase as $1
# (read by the caller before any SSH call), uploads the VM-side helpers, and runs
# keygen with the passphrase streamed over SSH on stdin (never argv, never disk).
setup_vault_passphrase() {
    local pp="$1"
    info "Ensuring passphrase-protected credential vault at \$HOME/.omp-vault…"
    remote "bash -lc 'mkdir -p ~/.omp-vault; command -v pass >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pass; command -v gpg >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg'" </dev/null >/dev/null
    upload "${SCRIPT_DIR}/platform/vault/init-vault.sh" '~/.omp-vault/init-vault.sh'
    upload "${SCRIPT_DIR}/platform/vault/preset.sh"     '~/.omp-vault/preset.sh'
    local out
    out=$(printf '%s\n' "${pp}" | gssh -- 'bash -lc "bash $HOME/.omp-vault/init-vault.sh"' 2>&1) \
        || die "vault init failed: ${out}"
    case "${out}" in
        *VAULT_OK*)     ok "Passphrase-protected vault created" ;;
        *VAULT_EXISTS*) warn "Vault already exists at ~/.omp-vault — left unchanged (passphrase not applied). Remove it on the VM to recreate." ;;
        *)              die "vault init: unexpected output: ${out}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Platform config subcommands
# ---------------------------------------------------------------------------
cmd_setup() {
    local passphrase_mode=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --passphrase) passphrase_mode=true; shift ;;
            *) die "Unknown setup option: $1 (use --passphrase)" ;;
        esac
    done

    # Read the passphrase up front, before any SSH call can consume stdin.
    local pp=""
    if [[ "${passphrase_mode}" == true ]]; then
        local pp2
        read -rsp "New vault passphrase: " pp; echo >&2
        read -rsp "Confirm passphrase:   " pp2; echo >&2
        [[ -n "${pp}" ]] || die "Empty passphrase."
        [[ "${pp}" == "${pp2}" ]] || die "Passphrases do not match."
    fi

    require_running

    # 1. Global secret obfuscation.
    info "Enabling omp secret obfuscation (global)…"
    local got
    got=$(remote "bash -lc 'omp config set secrets.enabled true >/dev/null 2>&1; omp config get secrets.enabled'" </dev/null | tr -d '[:space:]')
    [[ "${got}" == "true" ]] || die "secrets.enabled is '${got}', expected 'true'"
    ok "secrets.enabled=true"

    # 2. Credential vault.
    if [[ "${passphrase_mode}" == true ]]; then
        setup_vault_passphrase "${pp}"
    else
        # No-passphrase ed25519 (Tier-1: any in-session participant can decrypt).
        # For at-rest / other-local-user protection: ./manager.sh setup --passphrase
        info "Ensuring credential vault at \$HOME/.omp-vault (no passphrase)…"
        gssh -- 'bash -s' <<'VAULT' | grep -q VAULT_OK || die "vault init failed"
set -e
command -v pass >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pass
command -v gpg  >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg
VDIR="$HOME/.omp-vault"
export GNUPGHOME="$VDIR/gnupg" PASSWORD_STORE_DIR="$VDIR/store"
if [ ! -d "$PASSWORD_STORE_DIR" ]; then
  mkdir -p "$GNUPGHOME"; chmod 700 "$VDIR" "$GNUPGHOME"
  cat > /tmp/omp-vault-keyparams <<'KP'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Subkey-Type: ecdh
Subkey-Curve: cv25519
Name-Real: omp-vault
Name-Email: omp-vault@local
Expire-Date: 0
%commit
KP
  gpg --batch --gen-key /tmp/omp-vault-keyparams
  rm -f /tmp/omp-vault-keyparams
  KID=$(gpg --list-keys --with-colons omp-vault@local | awk -F: '/^pub/{print $5; exit}')
  pass init "$KID"
fi
echo VAULT_OK
VAULT
        ok "Vault ready"
    fi

    # 3. Global platform assets.
    info "Installing global platform assets to ~/.omp/agent/…"
    remote "mkdir -p ~/.omp/agent/rules ~/.omp/agent/commands"
    upload "${SCRIPT_DIR}/platform/AGENTS.md"   '~/.omp/agent/AGENTS.md'
    upload "${SCRIPT_DIR}/platform/RULES.md"    '~/.omp/agent/RULES.md'
    upload "${SCRIPT_DIR}/platform/secrets.yml" '~/.omp/agent/secrets.yml'

    # Behaviour/safety rule files.
    local f
    for f in "${SCRIPT_DIR}"/platform/rules/*.md; do
        upload "${f}" "~/.omp/agent/rules/$(basename "${f}")"
    done
    # Slash commands.
    upload "${SCRIPT_DIR}/platform/commands/commit-push-pr.md" '~/.omp/agent/commands/commit-push-pr.md'
    # Skills (one directory per skill under platform/skills/).
    local d name
    for d in "${SCRIPT_DIR}"/platform/skills/*/; do
        name="$(basename "${d}")"
        remote "mkdir -p ~/.omp/agent/skills/${name}"
        upload "${d}SKILL.md" "~/.omp/agent/skills/${name}/SKILL.md"
    done

    # 4. Portable agent tuning. Best-effort: ';'-chained (not '&&') so an unknown
    # key on a future omp version does not abort the rest of the batch.
    info "Applying portable agent tuning (omp config set)…"
    remote "bash -lc 'omp config set todo.eager always; omp config set search.contextBefore 1; omp config set search.contextAfter 1; omp config set readLineNumbers true; omp config set lsp.diagnosticsOnEdit true; omp config set steeringMode all; omp config set checkpoint.enabled true; omp config set async.enabled true; omp config set inspect_image.enabled true; omp config set task.isolation.mode rcopy; omp config set task.isolation.merge patch; omp config set task.isolation.commits ai; omp config set task.maxConcurrency 8; omp config set task.eager default; omp config set mcp.discoveryMode true; omp config set symbolPreset nerd; omp config set hideThinkingBlock false; omp config set providers.tinyModel lfm2-350m'" </dev/null \
        || warn "some omp config set keys were rejected (best-effort tuning)"

    # modelRoles is a JSON-record setting (the dotted 'modelRoles.<role>' form is not a
    # valid key), so set it as one record. Sent over a stdin login shell to keep the JSON's
    # double quotes out of the remote command string. Anthropic models the VM is already
    # authenticated for; no Ollama.
    info "Pinning model roles (Anthropic; VM is already authenticated)…"
    gssh -- 'bash -ls' <<'ROLES' | grep -q ROLES_OK || warn "modelRoles not set (best-effort)"
omp config set modelRoles '{"default":"anthropic/claude-sonnet-4-6","plan":"anthropic/claude-opus-4-8","slow":"anthropic/claude-haiku-4-5","smol":"anthropic/claude-haiku-4-5"}' >/dev/null 2>&1 && echo ROLES_OK
ROLES
    ok "Tuning applied (incl. modelRoles)"

    echo ""
    echo "SETUP_OK"
    echo "  ~/.omp/agent/AGENTS.md"
    echo "  ~/.omp/agent/RULES.md"
    echo "  ~/.omp/agent/secrets.yml"
    echo "  ~/.omp/agent/rules/  (5 behaviour/safety rules)"
    echo "  ~/.omp/agent/commands/commit-push-pr.md"
    echo "  ~/.omp/agent/skills/credential-access/SKILL.md"
    echo "  ~/.omp/agent/skills/mirantis-services/SKILL.md"
}

# Apply opt-in local-model tuning (no Ollama; both models are local ONNX, CPU,
# auto-downloaded from HF on first use). No flags applies both.
cmd_tune() {
    local do_memory=false do_thinking=false
    if [[ $# -eq 0 ]]; then
        do_memory=true; do_thinking=true
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --memory)   do_memory=true; shift ;;
            --thinking) do_thinking=true; shift ;;
            *) die "Unknown tune option: $1 (use --memory and/or --thinking)" ;;
        esac
    done

    require_running

    if [[ "${do_memory}" == true ]]; then
        info "Enabling mnemopi long-term memory (local ONNX model; no Ollama)…"
        remote "bash -lc 'omp config set memory.backend mnemopi; omp config set mnemopi.scoping per-project-tagged; omp config set mnemopi.noEmbeddings true; omp config set mnemopi.llmMode smol; omp config set providers.memoryModel qwen3-1.7b; omp config set memories.minRolloutIdleHours 6; omp config set memories.maxRolloutAgeDays 30; omp config set memories.summaryInjectionTokenLimit 5000'" </dev/null \
            || warn "some memory config keys were rejected (best-effort)"
        ok "memory.backend=mnemopi (providers.memoryModel=qwen3-1.7b)"
    fi

    if [[ "${do_thinking}" == true ]]; then
        info "Enabling automatic thinking-level selection (local ONNX model; no Ollama)…"
        remote "bash -lc 'omp config set defaultThinkingLevel auto; omp config set providers.autoThinkingModel qwen3-1.7b'" </dev/null \
            || warn "some thinking config keys were rejected (best-effort)"
        ok "defaultThinkingLevel=auto (providers.autoThinkingModel=qwen3-1.7b)"
    fi

    echo ""
    echo "TUNE_OK"
}

cmd_vault_add() {
    local entry="${1:-}"
    [[ -n "${entry}" ]] || die "Usage: ./manager.sh vault-add ENTRY   (value on stdin)"
    valid_token "${entry}" || die "Invalid entry name: ${entry}"
    require_running
    # The value arrives on local stdin and is streamed to the remote 'pass insert';
    # it never appears in argv/process list and is never echoed.
    remote "bash -lc 'export GNUPGHOME=\$HOME/.omp-vault/gnupg PASSWORD_STORE_DIR=\$HOME/.omp-vault/store; pass insert --multiline --force ${entry} >/dev/null'" \
        || die "vault-add failed for ${entry}"
    info "ADDED ${entry}"
}

cmd_vault_ls() {
    require_running
    local subtree="${1:-}"
    [[ -z "${subtree}" ]] || valid_token "${subtree}" || die "Invalid subtree: ${subtree}"
    remote "bash -lc 'export PASSWORD_STORE_DIR=\$HOME/.omp-vault/store; pass ls ${subtree} 2>/dev/null || echo \"(empty vault)\"'"
}

# ---------------------------------------------------------------------------
# Session lifecycle subcommands
# ---------------------------------------------------------------------------
cmd_list() {
    require_running
    info "tmux sessions on ${INSTANCE_NAME}:"
    remote "tmux ls 2>/dev/null || echo '  (no sessions)'"
}

cmd_new() {
    local name=""
    local -a subtrees=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subtree) subtrees+=("${2:?--subtree needs a value}"); shift 2 ;;
            *) [[ -z "${name}" ]] && name="$1"; shift ;;
        esac
    done
    [[ ${#subtrees[@]} -gt 0 ]] || subtrees=("${SUBTREE}")
    [[ -n "${name}" ]] || die "Usage: ./manager.sh new NAME [--subtree SUB]..."
    valid_name "${name}" || die "Invalid session name: ${name}"
    local s
    for s in "${subtrees[@]}"; do valid_token "$s" || die "Invalid subtree: $s"; done
    local subtree_list="${subtrees[*]}"
    require_running

    # Detect a passphrase-protected vault and read the passphrase up front, BEFORE
    # any stdin-consuming SSH call (e.g. session_exists), so a forwarded SSH channel
    # cannot swallow it. Read locally; never argv.
    local vault_pp=""
    if remote "test -f ~/.omp-vault/.passphrase-protected" </dev/null 2>/dev/null; then
        read -rsp "Vault passphrase: " vault_pp; echo >&2
        [[ -n "${vault_pp}" ]] || die "Empty passphrase; aborting."
    fi

    if session_exists "${name}"; then
        die "Session '${name}' already exists. Use: ./manager.sh attach ${name}"
    fi

    info "Provisioning session '${name}' (subtrees: ${subtree_list})…"
    # Seed the per-folder .omp/ and generate the env-injecting launcher. The
    # launcher contains only 'pass show' COMMANDS — never credential values — so it
    # is safe at rest (R-safe). Multiple subtrees are merged (later --subtree wins
    # on a name collision). Each entry's path maps to an env var: '/' and '-' → '_',
    # uppercased, non-[A-Z0-9_] stripped, e.g. services/github/token → GITHUB_TOKEN.
    # A structured 'key: value' entry exports one <ENTRY>_<KEY> var per line;
    # injecting the 'people' subtree thus namespaces per operator, e.g.
    # people/alice/atlassian → ALICE_ATLASSIAN_EMAIL / ALICE_ATLASSIAN_TOKEN.
    gssh -- "NAME='${name}' SUBTREES='${subtree_list}' bash -s" <<'NEW'
set -e
WD="$HOME/sessions/$NAME"
mkdir -p "$WD/.omp/skills"
for SUBTREE in $SUBTREES; do
  [ -d "$HOME/.omp-vault/store/$SUBTREE" ] || echo "WARN: vault subtree '$SUBTREE' is empty — nothing injected from it." >&2
done
{
  printf '#!/usr/bin/env bash\n'
  printf 'export GNUPGHOME="$HOME/.omp-vault/gnupg" PASSWORD_STORE_DIR="$HOME/.omp-vault/store"\n'
  printf 'SUBTREES=('; for s in $SUBTREES; do printf ' %q' "$s"; done; printf ' )\n'
  cat <<'LAUNCH'
for SUBTREE in "${SUBTREES[@]}"; do
  [ -d "$PASSWORD_STORE_DIR/$SUBTREE" ] || continue
  while IFS= read -r -d '' f; do
    rel="${f#${PASSWORD_STORE_DIR}/}"; rel="${rel%.gpg}"
    key="${rel#${SUBTREE}/}"
    base="$(printf '%s' "$key" | sed 's#[/-]#_#g' | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_]//g')"
    [ -n "$base" ] || continue
    content="$(pass show "$rel")"
    first="$(printf '%s\n' "$content" | head -1)"
    if printf '%s' "$first" | grep -qE '^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]'; then
      while IFS= read -r line; do
        printf '%s' "$line" | grep -qE '^[A-Za-z][A-Za-z0-9_-]*:[[:space:]]' || continue
        lk="${line%%:*}"; lv="${line#*:}"; lv="${lv#"${lv%%[![:space:]]*}"}"
        sub="$(printf '%s' "$lk" | sed 's#[/-]#_#g' | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_]//g')"
        [ -n "$sub" ] && export "${base}_${sub}=$lv"
      done < <(printf '%s\n' "$content")
    else
      export "$base=$first"
    fi
  done < <(find "$PASSWORD_STORE_DIR/$SUBTREE" -name '*.gpg' -print0 2>/dev/null)
done
LAUNCH
  printf 'cd %q\n' "$WD"
  printf 'exec omp\n'
} > "$WD/.omp/launch.sh"
chmod +x "$WD/.omp/launch.sh"
echo PROVISIONED
NEW

    # Seed per-folder config + context (AGENTS.md gets the session name).
    upload "${SCRIPT_DIR}/session-template/.omp/config.yml" "~/sessions/${name}/.omp/config.yml"
    sed "s/__SESSION_NAME__/${name}/g" "${SCRIPT_DIR}/session-template/.omp/AGENTS.md" \
        | remote "cat > ~/sessions/${name}/.omp/AGENTS.md"

    # Passphrase-protected vault: preset the passphrase into gpg-agent on the VM
    # right before launch so the detached launcher's `pass show` calls decrypt
    # without a pinentry prompt. Streamed over SSH on stdin; cached only in
    # gpg-agent memory (bounded by max-cache-ttl).
    if [[ -n "${vault_pp}" ]]; then
        info "Presetting vault passphrase into gpg-agent…"
        local pres
        pres=$(printf '%s\n' "${vault_pp}" | gssh -- 'bash -lc "bash $HOME/.omp-vault/preset.sh"' 2>&1) \
            || die "passphrase preset failed: ${pres}"
        case "${pres}" in *PRESET_OK*) ok "Passphrase cached for launch" ;; *) die "preset: unexpected output: ${pres}" ;; esac
    fi

    # Launch detached. bash -lc sources ~/.profile so omp is on PATH inside tmux.
    info "Launching omp under tmux…"
    remote "tmux new-session -d -s ${name} -x 220 -y 50 \"bash -lc \$HOME/sessions/${name}/.omp/launch.sh\""
    ok "Session '${name}' running."
    info "Attach with: ./manager.sh attach ${name}"
    info "Share with:  ./manager.sh collab ${name}"
}

cmd_attach() {
    require_running
    local name="${1:-}"
    if [[ -n "${name}" ]]; then
        valid_name "${name}" || die "Invalid session name: ${name}"
        session_exists "${name}" || die "Session '${name}' does not exist. Use: ./manager.sh new ${name}"
        info "Attaching to session '${name}'…"
    else
        name="$(resolve_session)"
        valid_name "${name}" || die "Refusing to attach: session name from the VM is unsafe: ${name}"
        info "Attaching to most recent session: '${name}'"
    fi
    remote_tty "tmux attach -t ${name}"
}

cmd_kill() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: ./manager.sh kill NAME"
    valid_name "${name}" || die "Invalid session name: ${name}"
    require_running
    session_exists "${name}" || die "Session '${name}' does not exist."
    info "Killing session '${name}'…"
    remote "tmux kill-session -t ${name}"
    info "Killed."
}

cmd_collab() {
    require_running
    local name; name="$(resolve_session "${1:-}")"
    valid_name "${name}" || die "Refusing to act on unsafe session name: ${name}"
    local mode="${2:-}"
    session_exists "${name}" || die "Session '${name}' does not exist."
    local slash="/collab"; [[ "${mode}" == "view" ]] && slash="/collab view"
    info "Requesting collab link from session '${name}'…"
    local link
    link=$(remote "tmux send-keys -t ${name} '${slash}' && sleep 1 && tmux send-keys -t ${name} Enter && sleep 8 && tmux capture-pane -p -J -S -25 -t ${name} | grep -oE 'omp join \"[^\"]+\"' | tail -1")
    if [[ -n "${link}" ]]; then
        echo "${link}"
    else
        warn "No join link found in pane; full capture follows:"
        remote "tmux capture-pane -p -J -S -40 -t ${name}"
    fi
}

cmd_help() {
    sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

case "${SUBCOMMAND}" in
    setup)          cmd_setup "$@" ;;
    tune)           cmd_tune "$@" ;;
    vault-add)      cmd_vault_add "$@" ;;
    vault-ls)       cmd_vault_ls "$@" ;;
    new)            cmd_new "$@" ;;
    attach|a)       cmd_attach "$@" ;;
    list|ls)        cmd_list "$@" ;;
    kill)           cmd_kill "$@" ;;
    collab)         cmd_collab "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown subcommand: ${SUBCOMMAND}" >&2
        echo "Run './manager.sh help' for usage." >&2
        exit 1
        ;;
esac
