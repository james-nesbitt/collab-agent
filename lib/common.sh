#!/usr/bin/env bash
# lib/common.sh — shared configuration and helpers for the remote-agent-machine
# tooling (administrator.sh + manager.sh). Sourced, never executed directly.
#
# A sourcing script SHOULD set LOG_TAG before sourcing (e.g. LOG_TAG=admin);
# it defaults to "omp".

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
GCP_PROJECT="${GCP_PROJECT:-tools-348616}"
INSTANCE_NAME="${INSTANCE_NAME:-omp-agent}"
ZONE="${ZONE:-europe-west1-b}"
REGION="${REGION:-europe-west1}"
USE_IAP="${USE_IAP:-true}"
LOG_TAG="${LOG_TAG:-omp}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
info() { echo "[${LOG_TAG}] $*"; }
warn() { echo "[${LOG_TAG}] WARN: $*"; }
ok()   { echo "[${LOG_TAG}] OK: $*"; }
die()  { echo "[${LOG_TAG}] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# SSH / remote execution
# ---------------------------------------------------------------------------
iap_flag() { [[ "${USE_IAP}" == "true" ]] && echo "--tunnel-through-iap" || echo ""; }

# gssh -- <remote-cmd>   or   gssh (interactive)
gssh() {
    gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        $(iap_flag) \
        "$@"
}

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

# ---------------------------------------------------------------------------
# GCP resource helpers
# ---------------------------------------------------------------------------
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
    [[ "${status}" == "RUNNING" ]] || die "Instance is not running (status: ${status}). Run: ./administrator.sh start"
}
