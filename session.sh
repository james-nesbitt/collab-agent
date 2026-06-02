#!/usr/bin/env bash
# session.sh — tmux session management on the omp-agent VM.
#
# Subcommands:
#   list                     List all tmux sessions on the VM
#   new NAME                 Create a new tmux session named NAME running omp,
#                            and attach. Errors if NAME already exists.
#   attach [NAME]            Attach to an existing tmux session.
#                            Without NAME: attaches to the most recent.
#                            Errors if NAME does not exist (use 'new' instead).
#   kill NAME                Kill a tmux session named NAME.
#   help                     Show this help
#
# Configuration (override via environment):
#   INSTANCE_NAME    (default: omp-agent)
#   ZONE             (default: europe-west1-b)
#   USE_IAP          (default: true) — tunnel SSH through IAP
set -euo pipefail

GCP_PROJECT="tools-348616"
INSTANCE_NAME="${INSTANCE_NAME:-omp-agent}"
ZONE="${ZONE:-europe-west1-b}"
USE_IAP="${USE_IAP:-true}"

info() { echo "[session] $*"; }
die()  { echo "[session] ERROR: $*" >&2; exit 1; }

iap_flag() { [[ "${USE_IAP}" == "true" ]] && echo "--tunnel-through-iap" || echo ""; }

# Non-interactive remote command (no TTY).
remote() {
    gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        $(iap_flag) \
        --command="$1"
}

# Interactive remote command with TTY (replaces current process).
remote_tty() {
    exec gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        $(iap_flag) \
        --ssh-flag='-t' \
        --command="$1"
}

require_running() {
    local status
    status=$(gcloud compute instances describe "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" --zone="${ZONE}" \
        --format="value(status)" 2>/dev/null || echo "NOT_FOUND")
    [[ "${status}" == "RUNNING" ]] || die "Instance is not running (status: ${status}). Run: ./manage.sh start"
}

# Return 0 if a tmux session named $1 exists on the remote.
session_exists() {
    remote "tmux has-session -t '$1' 2>/dev/null"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_list() {
    require_running
    info "tmux sessions on ${INSTANCE_NAME}:"
    remote "tmux ls 2>/dev/null || echo '  (no sessions)'"
}

cmd_new() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: ./session.sh new NAME"
    require_running

    if session_exists "${name}"; then
        die "Session '${name}' already exists. Use: ./session.sh attach ${name}"
    fi

    info "Creating session '${name}' and launching omp…"
    # bash -lc ensures ~/.profile is sourced so omp is on PATH inside tmux.
    remote_tty "bash -lc 'tmux new -s ${name} omp'"
}

cmd_attach() {
    require_running
    local name="${1:-}"

    if [[ -z "${name}" ]]; then
        # Pick the most recently used session.
        name=$(remote "tmux ls -F '#{session_last_attached} #{session_name}' 2>/dev/null \
                       | sort -rn | head -1 | awk '{print \$2}'" \
                       2>/dev/null | tr -d '[:space:]')
        [[ -n "${name}" ]] || die "No tmux sessions on the VM. Run: ./session.sh new NAME"
        info "Attaching to most recent session: '${name}'"
    else
        session_exists "${name}" || die "Session '${name}' does not exist. Use: ./session.sh new ${name}"
        info "Attaching to session '${name}'…"
    fi

    remote_tty "tmux attach -t ${name}"
}

cmd_kill() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: ./session.sh kill NAME"
    require_running

    session_exists "${name}" || die "Session '${name}' does not exist."
    info "Killing session '${name}'…"
    remote "tmux kill-session -t ${name}"
    info "Killed."
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
    list|ls)       cmd_list "$@" ;;
    new)           cmd_new "$@" ;;
    attach|a)      cmd_attach "$@" ;;
    kill)          cmd_kill "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown subcommand: ${SUBCOMMAND}" >&2
        echo "Run './session.sh help' for usage." >&2
        exit 1
        ;;
esac
