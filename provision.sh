#!/usr/bin/env bash
# provision.sh — Create GCP resources for the omp-agent VM.
#
# What this creates:
#   - Static external IP (so stop/start cycles keep the same address)
#   - Compute Engine VM (Ubuntu 24.04, e2-standard-4, 200GB pd-balanced)
#   - OS Login enabled, IAP SSH (no public SSH port needed)
#
# After provisioning, run:
#   ./manage.sh bootstrap   # installs tmux, mise, bun, omp on the VM
#   ./manage.sh connect     # SSH in and attach to a tmux session running omp
#
# Configuration (override via env):
#   GCP_PROJECT          required
#   INSTANCE_NAME        default: omp-agent
#   ZONE                 default: europe-west1-b
#   REGION               default: europe-west1
#   MACHINE_TYPE         default: e2-standard-4
#   DISK_SIZE            default: 200GB
#   DISK_TYPE            default: pd-balanced
#   STATIC_IP_NAME       default: omp-server-ip
set -euo pipefail

: "${GCP_PROJECT:?GCP_PROJECT must be set}"
INSTANCE_NAME="${INSTANCE_NAME:-omp-agent}"
ZONE="${ZONE:-europe-west1-b}"
REGION="${REGION:-europe-west1}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
DISK_SIZE="${DISK_SIZE:-200GB}"
DISK_TYPE="${DISK_TYPE:-pd-balanced}"
STATIC_IP_NAME="${STATIC_IP_NAME:-omp-server-ip}"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

resource_exists() {
    local subcmd=$1; shift
    local name=$1; shift
    gcloud ${subcmd} describe "${name}" "$@" --project="${GCP_PROJECT}" \
        --format="value(name)" 2>/dev/null | grep -q .
}

command -v gcloud >/dev/null || die "gcloud not found in PATH"

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
# 2. Create VM instance
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
echo "  Static IP : ${STATIC_IP}"
echo ""
echo "  Next steps:"
echo "    GCP_PROJECT=${GCP_PROJECT} ./manage.sh bootstrap"
echo "    GCP_PROJECT=${GCP_PROJECT} ./manage.sh connect"
echo "============================================================"
