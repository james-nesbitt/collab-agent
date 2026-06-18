#!/usr/bin/env bash
# administrator.sh — administrator role: GKE cluster lifecycle + IAM.
#
# Usage:
#   ./administrator.sh <subcommand> [args...]
#
# Subcommands:
#   provision                Create the GKE cluster, GCP service accounts, and IAM
#                            bindings (run once). Idempotent.
#   bootstrap                Install platform runtime on the cluster: RBAC, ESO,
#                            Session CRD, and the Session operator.
#   credentials              Fetch kubectl credentials for the cluster.
#   status                   Cluster summary + node + session list.
#   destroy                  Delete the cluster, GCP SAs, and IAM bindings.
#   help                     Show this help
#
# Images are published to GHCR by CI (.github/workflows/build-images.yml).
# For omp config + secret vault + session lifecycle, see ./manager.sh.
#
# Configuration (override via environment):
#   GCP_PROJECT        (default: tools-348616)
#   ZONE               (default: europe-west1-b)
#   REGION             (default: europe-west1)
#   CLUSTER_NAME       (default: omp-cluster)
#   NODE_MACHINE_TYPE  (default: e2-standard-4)
#   ADMIN_GCP_ACCOUNT  (default: current gcloud account)
#   OMP_REGISTRY       (default: ghcr.io/james-nesbitt/collab-agent)
#   OMP_IMAGE_TAG      (default: latest)
set -euo pipefail

# ---------------------------------------------------------------------------
# Shared config + helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="admin"
[[ -f "${SCRIPT_DIR}/lib/common.sh" ]] || { echo "[admin] ERROR: lib/common.sh not found" >&2; exit 1; }
. "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Administrator-only configuration
# ---------------------------------------------------------------------------
NODE_MACHINE_TYPE="${NODE_MACHINE_TYPE:-e2-standard-4}"
ADMIN_GCP_ACCOUNT="${ADMIN_GCP_ACCOUNT:-$(gcloud config get-value account 2>/dev/null)}"
OMP_REGISTRY="${OMP_REGISTRY:-ghcr.io/james-nesbitt/collab-agent}"
OMP_IMAGE_TAG="${OMP_IMAGE_TAG:-latest}"

# GCP service account emails
SA_ESO="omp-eso@${GCP_PROJECT}.iam.gserviceaccount.com"
SA_OPERATOR="omp-operator@${GCP_PROJECT}.iam.gserviceaccount.com"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# render <template-file> — envsubst the file to stdout using current env.
render() {
    local f="$1"
    [[ -f "${f}" ]] || die "manifest not found: ${f}"
    GCP_PROJECT="${GCP_PROJECT}" \
    ZONE="${ZONE}" \
    CLUSTER_NAME="${CLUSTER_NAME}" \
    REGION="${REGION}" \
    OMP_REGISTRY="${OMP_REGISTRY}" \
    OMP_IMAGE_TAG="${OMP_IMAGE_TAG}" \
        envsubst < "${f}"
}

# sa_exists <email> — return 0 if GCP SA exists.
sa_exists() {
    gcloud iam service-accounts describe "$1" \
        --project="${GCP_PROJECT}" --format="value(email)" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_provision() {
    command -v gcloud >/dev/null || die "gcloud not found in PATH"
    [[ -n "${ADMIN_GCP_ACCOUNT}" ]] || die "Could not determine admin GCP account. Set ADMIN_GCP_ACCOUNT."

    info "Project       : ${GCP_PROJECT}"
    info "Cluster       : ${CLUSTER_NAME}"
    info "Zone          : ${ZONE}"
    info "Machine       : ${NODE_MACHINE_TYPE}"
    info "Admin account : ${ADMIN_GCP_ACCOUNT}"

    # 1. Enable required APIs
    info "Enabling GCP APIs…"
    gcloud services enable \
        container.googleapis.com \
        secretmanager.googleapis.com \
        --project="${GCP_PROJECT}" --quiet

    # 2. GKE cluster
    if resource_exists "container clusters" "${CLUSTER_NAME}" --zone="${ZONE}"; then
        warn "Cluster '${CLUSTER_NAME}' already exists — skipping."
    else
        info "Creating GKE cluster '${CLUSTER_NAME}'…"
        gcloud container clusters create "${CLUSTER_NAME}" \
            --project="${GCP_PROJECT}" \
            --zone="${ZONE}" \
            --num-nodes=3 \
            --machine-type="${NODE_MACHINE_TYPE}" \
            --image-type=UBUNTU_CONTAINERD \
            --enable-dataplane-v2 \
            --workload-pool="${GCP_PROJECT}.svc.id.goog" \
            --no-enable-basic-auth \
            --no-issue-client-certificate \
            --release-channel=regular \
            --quiet
        ok "Cluster created."
    fi

    # 3. GCP service accounts
    if sa_exists "${SA_ESO}"; then
        warn "SA '${SA_ESO}' already exists — skipping."
    else
        info "Creating GCP SA for ESO (value reader)…"
        gcloud iam service-accounts create omp-eso \
            --project="${GCP_PROJECT}" \
            --description="ESO: reads GSM secret values for session namespaces" \
            --display-name="omp-eso"
        ok "SA omp-eso created."
    fi

    if sa_exists "${SA_OPERATOR}"; then
        warn "SA '${SA_OPERATOR}' already exists — skipping."
    else
        info "Creating GCP SA for operator (metadata viewer)…"
        gcloud iam service-accounts create omp-operator \
            --project="${GCP_PROJECT}" \
            --description="Session operator: lists GSM secret metadata" \
            --display-name="omp-operator"
        ok "SA omp-operator created."
    fi

    # 4. IAM roles
    info "Binding IAM roles…"
    gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
        --member="serviceAccount:${SA_ESO}" \
        --role="roles/secretmanager.secretAccessor" \
        --quiet
    gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
        --member="serviceAccount:${SA_OPERATOR}" \
        --role="roles/secretmanager.viewer" \
        --quiet

    # 5. Workload Identity bindings
    info "Binding Workload Identity for ESO…"
    gcloud iam service-accounts add-iam-policy-binding "${SA_ESO}" \
        --project="${GCP_PROJECT}" \
        --role="roles/iam.workloadIdentityUser" \
        --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[external-secrets/external-secrets]" \
        --quiet

    info "Binding Workload Identity for operator…"
    gcloud iam service-accounts add-iam-policy-binding "${SA_OPERATOR}" \
        --project="${GCP_PROJECT}" \
        --role="roles/iam.workloadIdentityUser" \
        --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[omp-system/omp-operator]" \
        --quiet

    # 6. Grant cluster access to admin account only; refuse if allUsers/allAuthenticatedUsers found
    info "Granting container.admin to ${ADMIN_GCP_ACCOUNT}…"
    gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
        --member="user:${ADMIN_GCP_ACCOUNT}" \
        --role="roles/container.admin" \
        --quiet

    # Paranoia check: refuse broad IAM on container resources
    local policy
    policy=$(gcloud projects get-iam-policy "${GCP_PROJECT}" --format=json 2>/dev/null)
    if echo "${policy}" | grep -qE '"allUsers"|"allAuthenticatedUsers"'; then
        die "SECURITY: project IAM contains allUsers or allAuthenticatedUsers bindings. Inspect and remove before continuing."
    fi

    echo ""
    echo "============================================================"
    echo "  Provisioning complete"
    echo "============================================================"
    echo "  Cluster  : ${CLUSTER_NAME}"
    echo "  Zone     : ${ZONE}"
    echo ""
    echo "  Next steps:"
    echo "    ./administrator.sh bootstrap"
    echo "    ./manager.sh setup"
    echo "    ./manager.sh new work"
    echo "============================================================"
}

cmd_bootstrap() {
    command -v kubectl >/dev/null || die "kubectl not found in PATH"
    command -v helm    >/dev/null || die "helm not found in PATH"

    info "Fetching cluster credentials…"
    cmd_credentials

    # 1. RBAC: bind admin account to cluster-admin
    info "Binding ${ADMIN_GCP_ACCOUNT} to cluster-admin…"
    kubectl create clusterrolebinding omp-admin \
        --clusterrole=cluster-admin \
        --user="${ADMIN_GCP_ACCOUNT}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # 2. External Secrets Operator via Helm
    info "Installing External Secrets Operator…"
    helm repo add external-secrets https://charts.external-secrets.io --force-update
    helm upgrade --install external-secrets external-secrets/external-secrets \
        -n external-secrets --create-namespace \
        --set installCRDs=true \
        --set "serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account=${SA_ESO}" \
        --wait

    # 3. Apply CRD, RBAC, operator Deployment (envsubst rendered)
    info "Applying Session CRD…"
    render "${SCRIPT_DIR}/k8s/crd-session.yaml" | kubectl apply -f -

    info "Applying operator RBAC…"
    render "${SCRIPT_DIR}/k8s/operator-rbac.yaml" | kubectl apply -f -

    info "Applying operator Deployment…"
    render "${SCRIPT_DIR}/k8s/operator-deploy.yaml" | kubectl apply -f -

    # 4. Wait for operator + ESO to be Available
    info "Waiting for operator to be Available…"
    kubectl rollout status deployment/omp-operator -n omp-system --timeout=120s
    info "Waiting for ESO to be Available…"
    kubectl rollout status deployment/external-secrets -n external-secrets --timeout=120s

    echo ""
    echo "BOOTSTRAP_OK"
    echo "  ESO running in ns external-secrets"
    echo "  Session operator running in ns omp-system"
    echo ""
    echo "  Next: ./manager.sh setup"
}

cmd_credentials() {
    info "Fetching kubectl credentials for cluster '${CLUSTER_NAME}'…"
    gcloud container clusters get-credentials "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${GCP_PROJECT}"
    ok "kubectl context: gke_${GCP_PROJECT}_${ZONE}_${CLUSTER_NAME}"
}

cmd_status() {
    require_cluster
    cmd_credentials >/dev/null 2>&1 || true
    info "Cluster:"
    gcloud container clusters describe "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${GCP_PROJECT}" \
        --format="table(name,status,currentNodeCount,currentMasterVersion)"
    echo ""
    info "Nodes:"
    kctl get nodes -o wide
    echo ""
    info "Sessions:"
    kctl get sessions -n omp-system 2>/dev/null || echo "  (no sessions)"
}

cmd_destroy() {
    echo ""
    echo "WARNING: This will permanently delete:"
    echo "  - GKE cluster  : ${CLUSTER_NAME} (${ZONE})"
    echo "  - GCP SA       : ${SA_ESO}"
    echo "  - GCP SA       : ${SA_OPERATOR}"
    echo "  - IAM bindings for both SAs"
    echo ""
    read -r -p "Type 'yes' to confirm: " confirm
    [[ "${confirm}" == "yes" ]] || { info "Aborted."; exit 0; }

    if resource_exists "container clusters" "${CLUSTER_NAME}" --zone="${ZONE}"; then
        info "Deleting cluster '${CLUSTER_NAME}'…"
        gcloud container clusters delete "${CLUSTER_NAME}" \
            --project="${GCP_PROJECT}" \
            --zone="${ZONE}" \
            --quiet
    else
        info "Cluster not found — skipping."
    fi

    for sa in "${SA_ESO}" "${SA_OPERATOR}"; do
        if sa_exists "${sa}"; then
            info "Deleting GCP SA '${sa}'…"
            gcloud iam service-accounts delete "${sa}" \
                --project="${GCP_PROJECT}" \
                --quiet || warn "SA delete failed for ${sa} (may have already been removed)"
        else
            info "SA '${sa}' not found — skipping."
        fi
    done

    ok "Destroy complete."
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
    bootstrap)      cmd_bootstrap "$@" ;;
    credentials)    cmd_credentials "$@" ;;
    status)         cmd_status "$@" ;;
    destroy)        cmd_destroy "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown subcommand: ${SUBCOMMAND}" >&2
        echo "Run './administrator.sh help' for usage." >&2
        exit 1
        ;;
esac
