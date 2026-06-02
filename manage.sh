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
#   build [OPTIONS]          Build the agent image on the remote instance.
#                            Transfers the local omp-server image to the VM
#                            via docker save|load (no registry needed), then
#                            runs docker buildx build on the VM.
#     --omp-image REPO:TAG   Local omp-server image to transfer (required)
#     --tag TAG              Output image tag (default: latest)
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
        gssh -- docker ps --filter name=omp-server \
            --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
            2>/dev/null || echo "  (SSH not yet available)"
    fi
}

cmd_logs() {
    require_running
    info "Tailing omp-server logs (Ctrl-C to stop)…"
    gssh -- docker logs omp-server -f "$@"
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
    gscp --recurse \
        "${INSTANCE_NAME}:/tmp/omp-clients/${user}.omp-client" \
        "${dest}/${user}.omp-client"

    info "Bundle saved to: ${dest}/${user}.omp-client"
}

cmd_setup() {
    require_running
    local remote_script="/tmp/setup-omp-server.sh"

    info "Copying setup-omp-server.sh to instance…"
    gscp "${SCRIPT_DIR}/setup-omp-server.sh" "${INSTANCE_NAME}:${remote_script}"

    info "Running setup on instance…"
    gssh -- sudo bash "${remote_script}" "$@"
}

cmd_build() {
    require_running
    local image_tag="latest"
    local image_repo="omp-server-agent"
    local remote_dir="/tmp/omp-build"
    local build_log="${remote_dir}/build.log"
    local omp_image=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)        shift; image_tag="$1" ;;
            --omp-image)  shift; omp_image="$1" ;;
        esac
        shift
    done

    [[ -n "${omp_image}" ]] || die "Specify the local omp-server image with --omp-image REPO:TAG"

    # Parse repo and tag from the omp_image argument.
    local omp_repo="${omp_image%%:*}"
    local omp_tag="${omp_image##*:}"
    [[ "${omp_repo}" == "${omp_tag}" ]] && omp_tag="latest"   # no colon given

    # Transfer the local omp-server image to the VM via docker save|load.
    # This avoids needing registry credentials on the remote host.
    info "Transferring ${omp_image} to instance (this may take a minute)…"
    docker save "${omp_image}" \
        | gcloud compute ssh "${INSTANCE_NAME}" \
              --project="${GCP_PROJECT}" \
              --zone="${ZONE}" \
              $(iap_flag) \
              -- sudo docker load

    info "Copying build context to instance…"
    gssh -- mkdir -p "${remote_dir}"
    gscp "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}/build-image.sh" \
        "${INSTANCE_NAME}:${remote_dir}/"

    # Query the real docker GID so the image grants socket access correctly.
    local docker_gid
    docker_gid=$(gssh -- getent group docker 2>/dev/null | cut -d: -f3)
    info "Docker GID on host: ${docker_gid}"

    # Run the build detached on the VM so SSH disconnections don't abort it.
    info "Starting build on instance (first build ~15 min)…"
    gssh -- "sudo nohup bash ${remote_dir}/build-image.sh \
                --output-repo ${image_repo} \
                --tag ${image_tag} \
                --build-arg OMP_BASE_REPO=${omp_repo} \
                --build-arg OMP_BASE_TAG=${omp_tag} \
                --build-arg DOCKER_GID=${docker_gid} \
                > ${build_log} 2>&1 & echo \$! > ${remote_dir}/build.pid
              echo 'Build PID:' \$(cat ${remote_dir}/build.pid)"

    # Tail the log; loop until the build process exits.
    info "Streaming build log (reconnects if SSH drops)…"
    local pid
    while true; do
        pid=$(gssh -- "cat ${remote_dir}/build.pid 2>/dev/null" 2>/dev/null || true)
        [[ -z "${pid}" ]] && { info "Build PID not found — may have already finished."; break; }
        gssh -- "tail -n +1 -f ${build_log} &
                 TAIL=\$!
                 while kill -0 ${pid} 2>/dev/null; do sleep 3; done
                 sleep 1; kill \$TAIL 2>/dev/null; wait \$TAIL 2>/dev/null" && break || true
        info "SSH dropped — reconnecting…"
        sleep 5
    done

    # Check exit status of the build.
    local exit_code
    exit_code=$(gssh -- "wait ${pid} 2>/dev/null; echo \$?" 2>/dev/null || echo "unknown")
    if [[ "${exit_code}" != "0" && "${exit_code}" != "unknown" ]]; then
        gssh -- "tail -30 ${build_log}" 2>/dev/null || true
        die "Build failed (exit ${exit_code}). See log above."
    fi

    # Update .env so the next compose up uses the freshly built image.
    info "Updating /opt/omp-server/.env…"
    gssh -- "sudo sed -i 's|^IMAGE_REPO=.*|IMAGE_REPO=${image_repo}|' /opt/omp-server/.env \
             && sudo sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=${image_tag}|' /opt/omp-server/.env"

    echo ""
    echo "  Image built : ${image_repo}:${image_tag}"
    echo "  Apply with  : GCP_PROJECT=${GCP_PROJECT} ./manage.sh setup -- --image ${image_repo}:${image_tag} --user <USER>"
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
