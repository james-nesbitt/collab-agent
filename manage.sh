#!/usr/bin/env bash
# manage.sh — Lifecycle management for the omp-agent GCP instance.
#
# Usage:
#   ./manage.sh <subcommand> [args...]
#
# Subcommands:
#   provision                Create the VM and reserve a static IP (run once)
#   start                    Start the stopped instance
#   stop                     Stop the running instance (disk persists)
#   ssh [-- EXTRA_ARGS]      Open a plain SSH session on the instance
#   bootstrap                Install tmux (system), mise + bun + omp (per-user).
#                            Idempotent. Run once per OS-Login user.
#   status                   Instance status and external IP
#   ip                       Print the reserved static external IP
#   destroy                  Tear down instance and static IP
#   help                     Show this help
#
# For tmux session management on the VM, see ./session.sh.
#
# Configuration (override via environment):
#   INSTANCE_NAME    (default: omp-agent)
#   ZONE             (default: europe-west1-b)
#   REGION           (default: europe-west1)
#   MACHINE_TYPE     (default: e2-standard-4)        — only used by provision
#   DISK_SIZE        (default: 200GB)                — only used by provision
#   DISK_TYPE        (default: pd-balanced)          — only used by provision
#   STATIC_IP_NAME   (default: omp-server-ip)
#   FIREWALL_RULE    (default: allow-omp-server)     — legacy, cleaned on destroy
#   USE_IAP          (default: true) — tunnel all SSH/SCP through IAP
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GCP_PROJECT="tools-348616"
INSTANCE_NAME="${INSTANCE_NAME:-omp-agent}"
ZONE="${ZONE:-europe-west1-b}"
REGION="${REGION:-europe-west1}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
DISK_SIZE="${DISK_SIZE:-200GB}"
DISK_TYPE="${DISK_TYPE:-pd-balanced}"
STATIC_IP_NAME="${STATIC_IP_NAME:-omp-server-ip}"
FIREWALL_RULE="${FIREWALL_RULE:-allow-omp-server}"
USE_IAP="${USE_IAP:-true}"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { echo "[manage] $*"; }
warn() { echo "[manage] WARN: $*"; }
ok()   { echo "[manage] OK: $*"; }
die()  { echo "[manage] ERROR: $*" >&2; exit 1; }

iap_flag()   { [[ "${USE_IAP}" == "true" ]] && echo "--tunnel-through-iap" || echo ""; }

gssh() {
    # gssh -- <remote-cmd>  or  gssh (interactive)
    gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        $(iap_flag) \
        "$@"
}

resource_exists() {
    # resource_exists <gcloud subcommand> <name> [extra flags...]
    local subcmd=$1; shift
    local name=$1; shift
    gcloud ${subcmd} describe "${name}" "$@" --project="${GCP_PROJECT}" \
        --format="value(name)" 2>/dev/null | grep -q .
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
cmd_provision() {
    command -v gcloud >/dev/null || die "gcloud not found in PATH"

    info "Project  : ${GCP_PROJECT}"
    info "Instance : ${INSTANCE_NAME}"
    info "Zone     : ${ZONE}"
    info "Machine  : ${MACHINE_TYPE}"
    info "Disk     : ${DISK_SIZE} ${DISK_TYPE}"

    # 1. Reserve static external IP
    if resource_exists "compute addresses" "${STATIC_IP_NAME}" --region="${REGION}"; then
        warn "Static IP '${STATIC_IP_NAME}' already exists — skipping."
    else
        info "Reserving static IP '${STATIC_IP_NAME}' in region ${REGION}…"
        gcloud compute addresses create "${STATIC_IP_NAME}" \
            --project="${GCP_PROJECT}" \
            --region="${REGION}" \
            --network-tier=PREMIUM
        ok "Static IP reserved."
    fi

    local static_ip
    static_ip=$(get_static_ip)
    info "Static IP: ${static_ip}"

    # 2. Create VM
    if resource_exists "compute instances" "${INSTANCE_NAME}" --zone="${ZONE}"; then
        warn "Instance '${INSTANCE_NAME}' already exists — skipping VM creation."
    else
        info "Creating instance '${INSTANCE_NAME}'…"
        gcloud compute instances create "${INSTANCE_NAME}" \
            --project="${GCP_PROJECT}" \
            --zone="${ZONE}" \
            --machine-type="${MACHINE_TYPE}" \
            --boot-disk-size="${DISK_SIZE}" \
            --boot-disk-type="${DISK_TYPE}" \
            --image-family="${IMAGE_FAMILY}" \
            --image-project="${IMAGE_PROJECT}" \
            --address="${static_ip}" \
            --network-tier=PREMIUM \
            --metadata="enable-oslogin=TRUE" \
            --scopes=default
        ok "Instance created."
    fi

    echo ""
    echo "============================================================"
    echo "  Provisioning complete"
    echo "============================================================"
    echo "  Instance  : ${INSTANCE_NAME}"
    echo "  Zone      : ${ZONE}"
    echo "  Static IP : ${static_ip}"
    echo ""
    echo "  Next steps:"
    echo "    ./manage.sh bootstrap"
    echo "    ./session.sh new work"
    echo "============================================================"
}

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
    info "Bootstrap complete. Run: ./session.sh new work"
}

cmd_status() {
    local status external_ip
    status=$(instance_status)
    external_ip=$(get_static_ip)

    echo "Instance  : ${INSTANCE_NAME}"
    echo "Zone      : ${ZONE}"
    echo "Status    : ${status}"
    echo "Static IP : ${external_ip:-<not reserved>}"

    if [[ "${status}" == "RUNNING" ]]; then
        echo ""
        echo "Manage tmux sessions with: ./session.sh"
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
    echo "  - Firewall    : ${FIREWALL_RULE} (legacy, if present)"
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

    if resource_exists "compute addresses" "${STATIC_IP_NAME}" --region="${REGION}"; then
        info "Releasing static IP '${STATIC_IP_NAME}'…"
        gcloud compute addresses delete "${STATIC_IP_NAME}" \
            --project="${GCP_PROJECT}" \
            --region="${REGION}" \
            --quiet
    else
        info "Static IP not found — skipping."
    fi

    if resource_exists "compute firewall-rules" "${FIREWALL_RULE}"; then
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
    provision)      cmd_provision "$@" ;;
    start)          cmd_start "$@" ;;
    stop)           cmd_stop "$@" ;;
    ssh)            cmd_ssh "$@" ;;
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
