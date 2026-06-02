#!/usr/bin/env bash
# manage.sh — Day-to-day operations for the omp-agent GCP instance.
#
# Usage:
#   ./manage.sh <subcommand> [args...]
#
# Subcommands:
#   start                    Start the stopped instance
#   stop                     Stop the running instance (data persists)
#   ssh [-- EXTRA_ARGS]      Open an SSH session on the instance
#   status                   Instance status, external IP, and container health
#   logs [-- EXTRA_ARGS]     Tail omp-server container logs (Ctrl-C to stop)
#   ip                       Print the reserved static external IP
#   get-client-bundle USER   SCP client bundle to ./clients/<USER>.omp-client/
#   build [TAG]              Build the agent image on the instance (default tag: latest)
#                            Copies Dockerfile + build-image.sh, runs build remotely,
#                            updates /opt/omp-server/.env. No registry required.
#   setup [-- EXTRA_ARGS]    Run setup-omp-server.sh on the instance via SSH
#   destroy                  Tear down instance, static IP, and firewall rule
#   help                     Show this help
#
# Configuration (override via environment):
#   GCP_PROJECT      (required)
#   INSTANCE_NAME    (default: omp-agent)
#   ZONE             (default: europe-west1-b)
#   REGION           (default: europe-west1)
#   STATIC_IP_NAME   (default: omp-server-ip)
#   FIREWALL_RULE    (default: allow-omp-server)
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { echo "[manage] $*"; }
die()  { echo "[manage] ERROR: $*" >&2; exit 1; }

gcp_flags() { echo "--project=${GCP_PROJECT} --zone=${ZONE}"; }

get_static_ip() {
    gcloud compute addresses describe "${STATIC_IP_NAME}" \
        --project="${GCP_PROJECT}" \
        --region="${REGION}" \
        --format="value(address)" 2>/dev/null || true
}

instance_status() {
    gcloud compute instances describe "${INSTANCE_NAME}" \
        $(gcp_flags) \
        --format="value(status)" 2>/dev/null || echo "NOT_FOUND"
}

require_running() {
    local status
    status=$(instance_status)
    [[ "${status}" == "RUNNING" ]] || die "Instance is not running (status: ${status}). Run: ./manage.sh start"
}

ssh_cmd() {
    # Emit the base gcloud ssh command as array elements.
    # Caller appends -- <remote command> or extra flags.
    echo gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}"
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
    exec gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        "$@"
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
        echo "Container health (via SSH):"
        gcloud compute ssh "${INSTANCE_NAME}" \
            --project="${GCP_PROJECT}" \
            --zone="${ZONE}" \
            -- docker ps --filter name=omp-server --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
            2>/dev/null || echo "  (SSH not yet available)"
    fi
}

cmd_logs() {
    require_running
    info "Tailing omp-server logs (Ctrl-C to stop)…"
    gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        -- docker logs omp-server -f "$@"
}

cmd_ip() {
    local ip
    ip=$(get_static_ip)
    if [[ -z "${ip}" ]]; then
        die "Static IP '${STATIC_IP_NAME}' not found."
    fi
    echo "${ip}"
}

cmd_get_client_bundle() {
    local user="$1"
    [[ -n "${user}" ]] || die "Usage: ./manage.sh get-client-bundle <USER>"
    require_running

    local dest="${SCRIPT_DIR}/clients"
    mkdir -p "${dest}"

    info "Copying ${user}.omp-client from instance…"
    gcloud compute scp \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        --recurse \
        "${INSTANCE_NAME}:/tmp/omp-clients/${user}.omp-client" \
        "${dest}/${user}.omp-client"

    info "Bundle saved to: ${dest}/${user}.omp-client"
}

cmd_setup() {
    require_running
    local remote_script="/tmp/setup-omp-server.sh"

    info "Copying setup-omp-server.sh to instance…"
    gcloud compute scp \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        "${SCRIPT_DIR}/setup-omp-server.sh" \
        "${INSTANCE_NAME}:${remote_script}"

    info "Running setup on instance…"
    gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        -- sudo bash "${remote_script}" "$@"
}

cmd_build() {
    require_running
    local image_tag="${1:-latest}"
    local image_repo="omp-server-agent"
    local remote_dir="/tmp/omp-build"

    info "Copying build context to instance…"
    gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        -- mkdir -p "${remote_dir}"

    gcloud compute scp \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        "${SCRIPT_DIR}/Dockerfile" \
        "${SCRIPT_DIR}/build-image.sh" \
        "${INSTANCE_NAME}:${remote_dir}/"

    info "Building ${image_repo}:${image_tag} on instance (first build ~10-15 min)…"
    gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        -- bash "${remote_dir}/build-image.sh" \
             --output-repo "${image_repo}" \
             --tag "${image_tag}"

    # Update .env so the next `docker compose up` uses the freshly built image.
    info "Updating /opt/omp-server/.env…"
    gcloud compute ssh "${INSTANCE_NAME}" \
        --project="${GCP_PROJECT}" \
        --zone="${ZONE}" \
        -- "sudo sed -i 's|^IMAGE_REPO=.*|IMAGE_REPO=${image_repo}|' /opt/omp-server/.env \
            && sudo sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=${image_tag}|' /opt/omp-server/.env"

    echo ""
    echo "  Image built: ${image_repo}:${image_tag}"
    echo "  To apply:    ./manage.sh ssh -- sudo docker compose -f /opt/omp-server/docker-compose.yml up -d"
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
    start)               cmd_start "$@" ;;
    stop)                cmd_stop "$@" ;;
    ssh)                 cmd_ssh "$@" ;;
    status)              cmd_status "$@" ;;
    logs)                cmd_logs "$@" ;;
    ip)                  cmd_ip "$@" ;;
    get-client-bundle)   cmd_get_client_bundle "$@" ;;
    build)               cmd_build "$@" ;;
    setup)               cmd_setup "$@" ;;
    destroy)             cmd_destroy "$@" ;;
    help|--help|-h)      cmd_help ;;
    *)
        echo "Unknown subcommand: ${SUBCOMMAND}" >&2
        echo "Run './manage.sh help' for usage." >&2
        exit 1
        ;;
esac
