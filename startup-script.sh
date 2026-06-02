#!/usr/bin/env bash
# startup-script.sh — First-boot VM provisioning via GCP startup-script mechanism.
#
# This script is idempotent: it checks for a sentinel file and exits early if
# provisioning has already been done. Docker CE and Podman are installed on the
# host VM; the omp-server compose directory is laid out. The container is NOT
# started here — that happens in setup-omp-server.sh after PKI init.
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
# 3. Install Podman (host daemon, rootful socket)
#
# The omp-server container mounts /run/podman/podman.sock and uses it as a
# remote socket (CONTAINER_HOST). The daemon never runs inside the container.
# ---------------------------------------------------------------------------
log "Installing Podman…"
apt-get install -y -qq podman

systemctl enable podman.socket
systemctl start podman.socket

log "Podman installed: $(podman --version)"
log "Podman socket: $(systemctl is-active podman.socket)"

# ---------------------------------------------------------------------------
# 4. Create omp-server directory and compose file
# ---------------------------------------------------------------------------
AGENT_MOUNT_DIR="/root/mount"

log "Creating ${OMP_DIR} and ${AGENT_MOUNT_DIR}…"
mkdir -p "${OMP_DIR}"
# Shared filespace: the same absolute path must exist on the host and be
# bind-mounted at that identical path inside the container. Never use ~ here.
mkdir -p "${AGENT_MOUNT_DIR}"

# docker-compose.yml — image reference is populated by setup-omp-server.sh
# via the .env file; the compose file uses variable substitution.
cat > "${OMP_DIR}/docker-compose.yml" << 'EOF'
services:
  omp-server:
    image: ${IMAGE_REPO}:${IMAGE_TAG}
    container_name: omp-server
    restart: unless-stopped
    privileged: true
    ports:
      - "7077:7077"
    volumes:
      - omp-data:/data
      # Docker socket — agents talk to the host Docker daemon
      - /var/run/docker.sock:/var/run/docker.sock
      # Podman socket — agents talk to the host Podman daemon (rootful)
      - /run/podman/podman.sock:/run/podman/podman.sock
      # Shared filespace — AGENT_MOUNT_DIR is the same absolute path on the
      # host and inside the container. docker/podman -v flags using this path
      # resolve correctly against the host daemon from anywhere.
      - ${AGENT_MOUNT_DIR}:${AGENT_MOUNT_DIR}
    environment:
      OMP_SERVER_DATA_DIR: /data
      OMP_SERVER_PKI_DIR: /data/pki
      OMP_SERVER_PORT: "7077"
      OMP_SERVER_URL: ${OMP_SERVER_URL}
      OMP_SERVER_LOG_LEVEL: ${OMP_SERVER_LOG_LEVEL:-info}
      # Point CLI tools at the host daemons via the mounted sockets
      DOCKER_HOST: unix:///var/run/docker.sock
      CONTAINER_HOST: unix:///run/podman/podman.sock
      # Expose the shared mount path so agent code can reference it without
      # hardcoding the directory
      AGENT_MOUNT_DIR: ${AGENT_MOUNT_DIR}
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
AGENT_MOUNT_DIR=/root/mount
EOF

# ---------------------------------------------------------------------------
# 5. Write sentinel
# ---------------------------------------------------------------------------
touch "${SENTINEL}"
log "Sentinel written to ${SENTINEL}."
log "First-boot provisioning complete."
log "SSH in and run setup-omp-server.sh to start omp-server."
