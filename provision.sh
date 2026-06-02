#!/usr/bin/env bash
# provision.sh — Create GCP resources for the omp-agent machine.
#
# Usage:
#   GCP_PROJECT=my-project ./provision.sh
#
# All variables below can be overridden from the environment.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
: "${GCP_PROJECT:?GCP_PROJECT must be set}"
INSTANCE_NAME="${INSTANCE_NAME:-omp-agent}"
ZONE="${ZONE:-europe-west1-b}"
REGION="${REGION:-europe-west1}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
DISK_SIZE="${DISK_SIZE:-200GB}"
DISK_TYPE="${DISK_TYPE:-pd-balanced}"
NETWORK_TAG="omp-server"
STATIC_IP_NAME="${STATIC_IP_NAME:-omp-server-ip}"
FIREWALL_RULE_NAME="${FIREWALL_RULE_NAME:-allow-omp-server}"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STARTUP_SCRIPT="${SCRIPT_DIR}/startup-script.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

resource_exists() {
    # resource_exists <gcloud subcommand> <name> [extra flags...]
    local subcmd=$1; shift
    local name=$1; shift
    gcloud ${subcmd} describe "${name}" "$@" --project="${GCP_PROJECT}" \
        --format="value(name)" 2>/dev/null | grep -q .
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
command -v gcloud >/dev/null || die "gcloud not found in PATH"
[[ -f "${STARTUP_SCRIPT}" ]] || die "startup-script.sh not found at ${STARTUP_SCRIPT}"

info "Project  : ${GCP_PROJECT}"
info "Instance : ${INSTANCE_NAME}"
info "Zone     : ${ZONE}"
info "Machine  : ${MACHINE_TYPE}"
info "Disk     : ${DISK_SIZE} ${DISK_TYPE}"

# ---------------------------------------------------------------------------
# 1. Reserve static external IP
# ---------------------------------------------------------------------------
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

STATIC_IP=$(gcloud compute addresses describe "${STATIC_IP_NAME}" \
    --project="${GCP_PROJECT}" \
    --region="${REGION}" \
    --format="value(address)")
info "Static IP: ${STATIC_IP}"

# ---------------------------------------------------------------------------
# 2. Create firewall rule for port 7077
# ---------------------------------------------------------------------------
if resource_exists "compute firewall-rules" "${FIREWALL_RULE_NAME}"; then
    warn "Firewall rule '${FIREWALL_RULE_NAME}' already exists — skipping."
else
    info "Creating firewall rule '${FIREWALL_RULE_NAME}'…"
    gcloud compute firewall-rules create "${FIREWALL_RULE_NAME}" \
        --project="${GCP_PROJECT}" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:7077 \
        --source-ranges=0.0.0.0/0 \
        --target-tags="${NETWORK_TAG}" \
        --description="Allow omp-server WebSocket connections on port 7077"
    ok "Firewall rule created."
fi

# ---------------------------------------------------------------------------
# 3. Create VM instance
# ---------------------------------------------------------------------------
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
        --address="${STATIC_IP}" \
        --network-tier=PREMIUM \
        --tags="${NETWORK_TAG}" \
        --metadata="enable-oslogin=TRUE" \
        --metadata-from-file="startup-script=${STARTUP_SCRIPT}" \
        --scopes=default
    ok "Instance created."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Provisioning complete"
echo "============================================================"
echo "  Instance  : ${INSTANCE_NAME}"
echo "  Zone      : ${ZONE}"
echo "  Static IP : ${STATIC_IP}"
echo ""
echo "  SSH (once the instance has finished first-boot setup):"
echo "    gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --project=${GCP_PROJECT}"
echo ""
echo "  Monitor startup script progress:"
echo "    gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --project=${GCP_PROJECT} \\"
echo "      -- sudo journalctl -f -u google-startup-scripts"
echo ""
echo "  After startup is complete, run:"
echo "    ./setup-omp-server.sh --image ghcr.io/OWNER/omp-server:latest"
echo "============================================================"
