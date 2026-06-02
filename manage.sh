#!/usr/bin/env bash
# manage.sh — Day-to-day operations for the omp-agent GCP instance.
#
# Usage:
#   ./manage.sh <subcommand> [args...]
#
# Subcommands:
#   start                    Start the stopped instance
#   stop                     Stop the running instance (data persists)
#   ssh [-- EXTRA_ARGS]      Open a plain SSH session on the instance
#   connect [SESSION]        SSH in, attach to tmux session (default: "work"),
#                            launching omp if the session is new
#   bootstrap                Install tmux (system), mise + bun + omp (per-user).
#                            Idempotent. Run once per OS-Login user.
#   status                   Instance status and external IP
#   ip                       Print the reserved static external IP
#   destroy                  Tear down instance and static IP
#   help                     Show this help
#
# Configuration (override via environment):
#   GCP_PROJECT      (required)
#   INSTANCE_NAME    (default: omp-agent)
#   ZONE             (default: europe-west1-b)
#   REGION           (default: europe-west1)
#   STATIC_IP_NAME   (default: omp-server-ip)
#   FIREWALL_RULE    (default: allow-omp-server)
#   USE_IAP          (default: true) — tunnel all SSH/SCP through IAP
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
: "${GCP_PROJECT:?GCP_PROJECT must be set}"
INSTANCE_NAME="${INSTANCE_NAME:-omp-agent}"
ZONE="${ZONE:-europe-west1-b}"
REGION="${REGION:-europe-west1}"
STATIC_IP_NAME="${STATIC_IP_NAME:-omp-server-ip}"
FIREWALL_RULE="${FIREWALL_RULE:-allow-omp-server}"
USE_IAP="${USE_IAP:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { echo "[manage] $*"; }
die()  { echo "[manage] ERROR: $*" >&2; exit 1; }

gcp_flags()  { echo "--project=${GCP_PROJECT} --zone=${ZONE}"; }
iap_flag()   { [[ "${USE_IAP}" == "true" ]] && echo "--tunnel-through-iap" || echo ""; }

# Wrappers that include IAP flag when enabled.
gssh() {
    # gssh -- <remote-cmd>  or  gssh (interactive)
    gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        $(iap_flag) \
        "$@"
}

gscp() {
    # gscp <src> <dst>
    gcloud compute scp \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        $(iap_flag) \
        "$@"
}

get_static_ip() {
    gcloud compute addresses describe "${STATIC_IP_NAME}" \
        --project="${GCP_PROJECT}" \
        --region="${REGION}" \
        --format="value(address)" 2>/dev/null || true
}

instance_status() {
    gcloud compute instances describe "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        --format="value(status)" 2>/dev/null || echo "NOT_FOUND"
}

require_running() {
    local status
    status=$(instance_status)
    [[ "${status}" == "RUNNING" ]] || die "Instance is not running (status: ${status}). Run: ./manage.sh start"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_start() {
    local status
    status=$(instance_status)
    if [[ "${status}" == "RUNNING" ]]; then
        info "Instance is already running."
        return
    fi
    info "Starting instance '${INSTANCE_NAME}'…"
    gcloud compute instances start "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}"
    info "Instance started. External IP: $(get_static_ip)"
}

cmd_stop() {
    local status
    status=$(instance_status)
    if [[ "${status}" == "TERMINATED" ]]; then
        info "Instance is already stopped."
        return
    fi
    info "Stopping instance '${INSTANCE_NAME}'…"
    gcloud compute instances stop "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}"
    info "Instance stopped."
}

cmd_ssh() {
    require_running
    exec gssh "$@"
}

cmd_connect() {
    require_running
    local session="${1:-work}"
    # tmux new -A: attach if session exists, create+run command if not.
    # bash -lc: ensures ~/.profile is sourced so omp is on PATH (in case the
    # session is brand new and tmux execs the command via /bin/sh which would
    # otherwise miss the user's login environment).
    exec gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        $(iap_flag) \
        --ssh-flag='-t' \
        --command="bash -lc 'tmux new -A -s ${session} omp'"
}


cmd_bootstrap() {
    require_running
    info "Bootstrapping tmux/mise/bun/omp on instance for SSH user…"
    # Heredoc-streamed installer that runs as whoever SSHs in (OS Login user).
    # System tmux is sudo'd; mise/bun/omp install into the user's $HOME.
    gssh -- 'bash -s' << 'BOOTSTRAP'
set -e
echo "[bootstrap] user: $(whoami)"

# tmux (system)
if ! command -v tmux >/dev/null; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux curl unzip git
fi

# mise (user)
if [ ! -x ~/.local/bin/mise ]; then
  curl -fsSL https://mise.run | sh
fi

# PATH wiring — covers login (~/.profile), interactive (~/.bashrc),
# and tmux-spawned non-login shells (PATH is inherited from the parent).
grep -q '.bun/bin' ~/.profile 2>/dev/null || cat >> ~/.profile <<'PRF'

# mise + bun PATH
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
eval "$(~/.local/bin/mise activate bash --shims)" 2>/dev/null || true
PRF
grep -q 'mise activate' ~/.bashrc 2>/dev/null || \
  echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc

# bun via mise
~/.local/bin/mise use -g bun@latest >/dev/null

# omp via bun
~/.local/bin/mise exec bun -- bun install -g @oh-my-pi/pi-coding-agent

echo ""
echo "[bootstrap] versions:"
tmux -V
~/.local/bin/mise --version
~/.local/bin/mise exec bun -- bun --version
PATH="$HOME/.bun/bin:$PATH" ~/.local/bin/mise exec bun -- omp --version
BOOTSTRAP
    info "Bootstrap complete. Run: ./manage.sh connect"
}
cmd_status() {
    local status external_ip container_status
    status=$(instance_status)
    external_ip=$(get_static_ip)

    echo "Instance  : ${INSTANCE_NAME}"
    echo "Zone      : ${ZONE}"
    echo "Status    : ${status}"
    echo "Static IP : ${external_ip:-<not reserved>}"

    if [[ "${status}" == "RUNNING" ]]; then
        echo ""
        echo "Connect with:"
        echo "  ./manage.sh connect"
    fi
}

cmd_ip() {
    local ip
    ip=$(get_static_ip)
    [[ -z "${ip}" ]] && die "Static IP '${STATIC_IP_NAME}' not found."
    echo "${ip}"
}

cmd_destroy() {
    echo ""
    echo "WARNING: This will permanently delete:"
    echo "  - Instance    : ${INSTANCE_NAME} (${ZONE})"
    echo "  - Static IP   : ${STATIC_IP_NAME} (${REGION})"
    echo "  - Firewall    : ${FIREWALL_RULE}"
    echo ""
    read -r -p "Type 'yes' to confirm: " confirm
    [[ "${confirm}" == "yes" ]] || { info "Aborted."; exit 0; }

    local status
    status=$(instance_status)
    if [[ "${status}" != "NOT_FOUND" ]]; then
        info "Deleting instance '${INSTANCE_NAME}'…"
        gcloud compute instances delete "${INSTANCE_NAME}" \
            --project="${GCP_PROJECT}" \
            --zone="${ZONE}" \
            --quiet
    else
        info "Instance not found — skipping."
    fi

    if gcloud compute addresses describe "${STATIC_IP_NAME}" \
            --project="${GCP_PROJECT}" --region="${REGION}" &>/dev/null; then
        info "Releasing static IP '${STATIC_IP_NAME}'…"
        gcloud compute addresses delete "${STATIC_IP_NAME}" \
            --project="${GCP_PROJECT}" \
            --region="${REGION}" \
            --quiet
    else
        info "Static IP not found — skipping."
    fi

    if gcloud compute firewall-rules describe "${FIREWALL_RULE}" \
            --project="${GCP_PROJECT}" &>/dev/null; then
        info "Deleting firewall rule '${FIREWALL_RULE}'…"
        gcloud compute firewall-rules delete "${FIREWALL_RULE}" \
            --project="${GCP_PROJECT}" \
            --quiet
    else
        info "Firewall rule not found — skipping."
    fi

    info "Destroy complete."
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
    start)          cmd_start "$@" ;;
    stop)           cmd_stop "$@" ;;
    ssh)            cmd_ssh "$@" ;;
    connect)        cmd_connect "$@" ;;
    bootstrap)      cmd_bootstrap "$@" ;;
    status)         cmd_status "$@" ;;
    ip)             cmd_ip "$@" ;;
    destroy)        cmd_destroy "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown subcommand: ${SUBCOMMAND}" >&2
        echo "Run './manage.sh help' for usage." >&2
        exit 1
        ;;
esac
