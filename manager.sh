#!/usr/bin/env bash
# manager.sh — manager role: omp platform configuration + tmux session lifecycle
# on the omp-agent VM.
#
# Usage:
#   ./manager.sh <subcommand> [args...]
#
# Platform config (global, idempotent):
#   setup                    Enable secret obfuscation, ensure the credential
#                            vault, and install global skills/RULES.md/AGENTS.md.
#   vault-add ENTRY          Insert a vault entry (value read from stdin, never
#                            echoed), e.g.  printf '%s' "$TOK" | ./manager.sh \
#                            vault-add services/github/token
#   vault-ls [SUBTREE]       List vault entry NAMES only (no values).
#
# Session lifecycle:
#   new NAME [--subtree SUB] Create a detached tmux session running omp, with a
#                            seeded per-folder .omp/ and the vault SUBTREE
#                            (default: services) injected as env vars.
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

# ---------------------------------------------------------------------------
# Platform config subcommands
# ---------------------------------------------------------------------------
cmd_setup() {
    require_running

    # 1. Global secret obfuscation.
    info "Enabling omp secret obfuscation (global)…"
    local got
    got=$(remote "bash -lc 'omp config set secrets.enabled true >/dev/null 2>&1; omp config get secrets.enabled'" | tr -d '[:space:]')
    [[ "${got}" == "true" ]] || die "secrets.enabled is '${got}', expected 'true'"
    ok "secrets.enabled=true"

    # 2. Credential vault (no-passphrase ed25519 — documented Tier-1 boundary:
    #    any in-session participant can decrypt; Tier-2 OS isolation is the fix).
    info "Ensuring credential vault at \$HOME/.omp-vault…"
    gssh -- 'bash -s' <<'VAULT' | grep -q VAULT_OK || die "vault init failed"
set -e
command -v pass >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pass
command -v gpg  >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg
VDIR="$HOME/.omp-vault"
export GNUPGHOME="$VDIR/gnupg" PASSWORD_STORE_DIR="$VDIR/store"
if [ ! -d "$PASSWORD_STORE_DIR" ]; then
  mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
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

    # 3. Global platform assets.
    info "Installing global platform assets to ~/.omp/agent/…"
    remote "mkdir -p ~/.omp/agent/skills/credential-access"
    upload "${SCRIPT_DIR}/platform/AGENTS.md"                        '~/.omp/agent/AGENTS.md'
    upload "${SCRIPT_DIR}/platform/RULES.md"                         '~/.omp/agent/RULES.md'
    upload "${SCRIPT_DIR}/platform/secrets.yml"                      '~/.omp/agent/secrets.yml'
    upload "${SCRIPT_DIR}/platform/skills/credential-access/SKILL.md" '~/.omp/agent/skills/credential-access/SKILL.md'

    echo ""
    echo "SETUP_OK"
    echo "  ~/.omp/agent/AGENTS.md"
    echo "  ~/.omp/agent/RULES.md"
    echo "  ~/.omp/agent/secrets.yml"
    echo "  ~/.omp/agent/skills/credential-access/SKILL.md"
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
    local name="" subtree="${SUBTREE}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subtree) subtree="${2:-}"; shift 2 || die "--subtree needs a value" ;;
            *) [[ -z "${name}" ]] && name="$1"; shift ;;
        esac
    done
    [[ -n "${name}" ]] || die "Usage: ./manager.sh new NAME [--subtree SUBTREE]"
    valid_token "${name}"    || die "Invalid session name: ${name}"
    valid_token "${subtree}" || die "Invalid subtree: ${subtree}"
    require_running

    if session_exists "${name}"; then
        die "Session '${name}' already exists. Use: ./manager.sh attach ${name}"
    fi

    info "Provisioning session '${name}' (subtree: ${subtree})…"
    # Seed the per-folder .omp/ and generate the env-injecting launcher. The
    # launcher contains only 'pass show' COMMANDS — never credential values —
    # so it is safe at rest (R-safe). Entry path under the subtree maps to an
    # env var: '/' and '-' → '_', uppercased, non-[A-Z0-9_] stripped, e.g.
    # services/github/token → GITHUB_TOKEN (matches omp's TOKEN secret pattern).
    gssh -- "NAME='${name}' SUBTREE='${subtree}' bash -s" <<'NEW'
set -e
WD="$HOME/sessions/$NAME"
mkdir -p "$WD/.omp/skills"
if [ ! -d "$HOME/.omp-vault/store/$SUBTREE" ]; then
  echo "WARN: vault subtree '$SUBTREE' is empty — launcher will export nothing." >&2
fi
{
  printf '#!/usr/bin/env bash\n'
  printf 'export GNUPGHOME="$HOME/.omp-vault/gnupg" PASSWORD_STORE_DIR="$HOME/.omp-vault/store"\n'
  printf 'SUBTREE=%q\n' "$SUBTREE"
  cat <<'LAUNCH'
while IFS= read -r -d '' f; do
  rel="${f#${PASSWORD_STORE_DIR}/}"; rel="${rel%.gpg}"
  key="${rel#${SUBTREE}/}"
  vname="$(printf '%s' "$key" | sed 's#[/-]#_#g' | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_]//g')"
  [ -n "$vname" ] && export "$vname=$(pass show "$rel" | head -1)"
done < <(find "$PASSWORD_STORE_DIR/$SUBTREE" -name '*.gpg' -print0 2>/dev/null)
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
    if [[ -z "${name}" ]]; then
        name="$(resolve_session)"
        info "Attaching to most recent session: '${name}'"
    else
        session_exists "${name}" || die "Session '${name}' does not exist. Use: ./manager.sh new ${name}"
        info "Attaching to session '${name}'…"
    fi
    remote_tty "tmux attach -t ${name}"
}

cmd_kill() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: ./manager.sh kill NAME"
    require_running
    session_exists "${name}" || die "Session '${name}' does not exist."
    info "Killing session '${name}'…"
    remote "tmux kill-session -t ${name}"
    info "Killed."
}

cmd_collab() {
    require_running
    local name; name="$(resolve_session "${1:-}")"
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
