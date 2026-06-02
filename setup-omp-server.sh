#!/usr/bin/env bash
# setup-omp-server.sh — Post-provision setup: pull image, init PKI, register users.
#
# Run this ONCE after the VM has finished its first-boot startup script, either:
#   a) Directly on the instance:  ./setup-omp-server.sh [OPTIONS]
#   b) Via manage.sh:             ./manage.sh setup [OPTIONS]
#
# Usage:
#   ./setup-omp-server.sh [OPTIONS]
#
# Options:
#   --image  IMAGE_REPO:TAG   Full image reference (default: ghcr.io/OWNER/omp-server:latest)
#   --user   USERNAME         Register this user after PKI init (can repeat)
#   --ghcr-token TOKEN        GitHub PAT with read:packages scope (only if image is private)
#   --hostname HOSTNAME       Hostname baked into PKI and client bundles
#                             (default: auto-detected from instance metadata)
#   --clients-dir DIR         Where to copy client bundles (default: /tmp/omp-clients)
#   --help                    Show this help
#
# After running, retrieve client bundles from the instance with:
#   ./manage.sh get-client-bundle <USER>
set -euo pipefail

OMP_DIR="/opt/omp-server"
CLIENTS_DIR="/tmp/omp-clients"
HOSTNAME_OVERRIDE=""
IMAGE_REPO="ghcr.io/OWNER/omp-server"
IMAGE_TAG="latest"
GHCR_TOKEN=""
USERS=()

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            shift
            IMAGE="$1"
            IMAGE_REPO="${IMAGE%%:*}"
            IMAGE_TAG="${IMAGE##*:}"
            ;;
        --user)
            shift
            USERS+=("$1")
            ;;
        --ghcr-token)
            shift
            GHCR_TOKEN="$1"
            ;;
        --hostname)
            shift
            HOSTNAME_OVERRIDE="$1"
            ;;
        --clients-dir)
            shift
            CLIENTS_DIR="$1"
            ;;
        --help|-h)
            sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

log()  { echo "[setup-omp] $*"; }
die()  { echo "[setup-omp] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Determine hostname
# ---------------------------------------------------------------------------
if [[ -n "${HOSTNAME_OVERRIDE}" ]]; then
    OMP_HOSTNAME="${HOSTNAME_OVERRIDE}"
else
    # Try GCP instance metadata for the external IP (baked into client bundles).
    # Falls back to the internal hostname if metadata is unavailable.
    OMP_HOSTNAME=$(
        curl -sf \
            --connect-timeout 2 \
            -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
        2>/dev/null || hostname -f
    )
fi
log "Using hostname/IP: ${OMP_HOSTNAME}"
OMP_SERVER_URL="wss://${OMP_HOSTNAME}:7077"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[[ -d "${OMP_DIR}" ]] || die "${OMP_DIR} not found — did the startup script complete?"
command -v docker >/dev/null || die "docker not found"

# ---------------------------------------------------------------------------
# 1. Authenticate to GHCR (if token provided)
# ---------------------------------------------------------------------------
if [[ -n "${GHCR_TOKEN}" ]]; then
    log "Authenticating to ghcr.io…"
    echo "${GHCR_TOKEN}" | docker login ghcr.io -u _ --password-stdin
    log "GHCR login successful."
fi

# ---------------------------------------------------------------------------
# 2. Write .env
# ---------------------------------------------------------------------------
log "Writing ${OMP_DIR}/.env…"
cat > "${OMP_DIR}/.env" << EOF
IMAGE_REPO=${IMAGE_REPO}
IMAGE_TAG=${IMAGE_TAG}
OMP_SERVER_URL=${OMP_SERVER_URL}
AGENT_MOUNT_DIR=/home/ubuntu/mount
EOF

# ---------------------------------------------------------------------------
# 3. Pull image
# ---------------------------------------------------------------------------
log "Pulling ${IMAGE_REPO}:${IMAGE_TAG}…"
docker pull "${IMAGE_REPO}:${IMAGE_TAG}"

# ---------------------------------------------------------------------------
# 4. Initialise omp-data volume ownership
#
# Docker named volumes are created root:root. The server runs as uid=1000 and
# cannot write to /data without this one-time fix. Using a minimal alpine
# container avoids pulling the full omp-server image just for a chown.
# ---------------------------------------------------------------------------
log "Initialising omp-data volume ownership (uid=1000)…"
docker volume create omp-data 2>/dev/null || true
docker run --rm \
    -v omp-data:/data \
    alpine \
    chown -R 1000:1000 /data

# ---------------------------------------------------------------------------
# 5. Start container
# ---------------------------------------------------------------------------
log "Starting omp-server via docker compose…"
cd "${OMP_DIR}"
docker compose up -d

# Wait for container to be healthy (up to 60 s)
log "Waiting for omp-server to become healthy…"
for i in $(seq 1 12); do
    status=$(docker inspect --format='{{.State.Health.Status}}' omp-server 2>/dev/null || true)
    if [[ "${status}" == "healthy" ]]; then
        log "Container is healthy."
        break
    fi
    if [[ "${status}" == "unhealthy" ]]; then
        docker logs omp-server --tail 30
        die "Container entered unhealthy state. Check logs above."
    fi
    log "  (${i}/12) status=${status:-starting} — waiting 5 s…"
    sleep 5
done

# ---------------------------------------------------------------------------
# 5. Initialise PKI
# ---------------------------------------------------------------------------
# Only init if PKI doesn't already exist (idempotent guard).
if docker exec omp-server test -f /data/pki/ca.crt 2>/dev/null; then
    log "PKI already initialised — skipping init."
else
    log "Initialising PKI for hostname '${OMP_HOSTNAME}'…"
    docker exec omp-server bun run dist/main.js init "${OMP_HOSTNAME}"
    log "PKI initialised."
fi

# ---------------------------------------------------------------------------
# 6. Register users
# ---------------------------------------------------------------------------
mkdir -p "${CLIENTS_DIR}"

for user in "${USERS[@]}"; do
    log "Registering user '${user}'…"
    docker exec omp-server bun run dist/main.js register "${user}"

    log "Copying client bundle for '${user}'…"
    docker cp "omp-server:/app/.clients/${user}.omp-client" "${CLIENTS_DIR}/${user}.omp-client"
    log "  Bundle: ${CLIENTS_DIR}/${user}.omp-client"
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  omp-server setup complete"
echo "============================================================"
echo "  Server URL : ${OMP_SERVER_URL}"
echo "  Image      : ${IMAGE_REPO}:${IMAGE_TAG}"
if [[ ${#USERS[@]} -gt 0 ]]; then
    echo "  Clients    : ${CLIENTS_DIR}/"
    for user in "${USERS[@]}"; do
        echo "    ${user}.omp-client"
    done
    echo ""
    echo "  Retrieve bundles from your workstation with:"
    echo "    ./manage.sh get-client-bundle <USER>"
fi
echo ""
echo "  Health check:"
echo "    curl -k https://${OMP_HOSTNAME}:7077/healthz"
echo "============================================================"
