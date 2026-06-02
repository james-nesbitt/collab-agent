#!/usr/bin/env bash
# startup-script.sh — First-boot VM provisioning via GCP startup-script mechanism.
#
# This script is idempotent: it checks for a sentinel file and exits early if
# provisioning has already been done. Docker CE is installed and the
# omp-server compose directory is laid out; the container is NOT started here
# (that happens in setup-omp-server.sh after PKI init).
set -euo pipefail

SENTINEL="/opt/omp-provisioned"
OMP_DIR="/opt/omp-server"

log() { echo "[startup-script] $*"; }

if [[ -f "${SENTINEL}" ]]; then
    log "Sentinel found — already provisioned. Exiting."
    exit 0
fi

log "Starting first-boot provisioning…"

# ---------------------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# ---------------------------------------------------------------------------
# 2. Install Docker CE (official repo)
# ---------------------------------------------------------------------------
log "Installing Docker CE…"
apt-get install -y -qq ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable docker
systemctl start docker

log "Docker installed: $(docker --version)"

# ---------------------------------------------------------------------------
# 3. Create omp-server directory and compose file
# ---------------------------------------------------------------------------
log "Creating ${OMP_DIR}…"
mkdir -p "${OMP_DIR}"

# docker-compose.yml — image reference is populated by setup-omp-server.sh
# via the .env file; the compose file uses variable substitution.
cat > "${OMP_DIR}/docker-compose.yml" << 'EOF'
services:
  omp-server:
    image: ${IMAGE_REPO}:${IMAGE_TAG}
    container_name: omp-server
    restart: unless-stopped
    ports:
      - "7077:7077"
    volumes:
      - omp-data:/data
    environment:
      OMP_SERVER_DATA_DIR: /data
      OMP_SERVER_PKI_DIR: /data/pki
      OMP_SERVER_PORT: "7077"
      OMP_SERVER_URL: ${OMP_SERVER_URL}
      OMP_SERVER_LOG_LEVEL: ${OMP_SERVER_LOG_LEVEL:-info}
    healthcheck:
      test: ["CMD", "bun", "-e",
        "const r = await fetch('https://localhost:7077/healthz', {tls:{rejectUnauthorized:false}}); if(!r.ok) process.exit(1)"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

volumes:
  omp-data:
EOF

# .env stub — populated by setup-omp-server.sh
cat > "${OMP_DIR}/.env" << 'EOF'
# Populated by setup-omp-server.sh — do not hand-edit while container is running.
IMAGE_REPO=ghcr.io/OWNER/omp-server
IMAGE_TAG=latest
OMP_SERVER_URL=
EOF

# ---------------------------------------------------------------------------
# 4. Write sentinel
# ---------------------------------------------------------------------------
touch "${SENTINEL}"
log "Sentinel written to ${SENTINEL}."
log "First-boot provisioning complete."
log "SSH in and run setup-omp-server.sh to start omp-server."
