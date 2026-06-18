#!/usr/bin/env bash
# administrator.sh — administrator role: GKE cluster lifecycle + IAM + platform config + vault.
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
#   setup                    Configure the ESO ClusterSecretStore, create/update the
#                            master omp-config ConfigMap in omp-system (secrets.enabled,
#                            modelRoles, portable tuning), and print SETUP_OK.
#   vault-add ENTRY          Insert a credential into GCP Secret Manager (value read
#                            from stdin, never echoed). Entry format: subtree/key/...
#                            e.g.  printf '%s' "$TOK" | ./administrator.sh vault-add \
#                            services/github/token
#   vault-ls [SUBTREE]       List vault entry NAMES only (no values).
#   tune [--memory] [--thinking]
#                            Patch the master omp-config ConfigMap with opt-in tuning:
#                            mnemopi long-term memory (--memory) and/or automatic
#                            thinking-level selection (--thinking). No flag = both.
#                            New sessions pick it up; running pods on next restart.
#   help                     Show this help
#
# Session lifecycle (new/login/attach/list/kill/collab) is handled directly with
# kubectl; see the manager skill.
#
# Images are published to GHCR by CI (.github/workflows/build-images.yml).
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
#   SUBTREE            (default: services) — vault subtree
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

SUBTREE="${SUBTREE:-services}"
SESSION_NS="omp-system"

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

# Detect the served ESO API version (v1 or v1beta1).
eso_api_version() {
    local versions
    versions=$(kubectl get crd externalsecrets.external-secrets.io \
               -o jsonpath='{.spec.versions[*].name}' 2>/dev/null || echo "")
    if echo "${versions}" | grep -qw "v1"; then
        echo "external-secrets.io/v1"
    else
        echo "external-secrets.io/v1beta1"
    fi
}

# Validate a session/subtree token (no shell metacharacters → safe to interpolate).
valid_token() { [[ "$1" =~ ^[A-Za-z0-9_/-]+$ ]]; }

# Build the omp config.yml content (base tuning block).
_base_config_yml() {
    cat <<'CONFIG'
# omp platform config — managed by administrator.sh setup/tune
secrets:
  enabled: true
modelRoles:
  default: anthropic/claude-sonnet-4-6
  plan: anthropic/claude-opus-4-8
  slow: anthropic/claude-haiku-4-5
  smol: anthropic/claude-haiku-4-5
todo:
  eager: always
search:
  contextBefore: 1
  contextAfter: 1
readLineNumbers: true
lsp:
  diagnosticsOnEdit: true
steeringMode: all
checkpoint:
  enabled: true
async:
  enabled: true
inspect_image:
  enabled: true
task:
  isolation:
    mode: rcopy
    merge: patch
    commits: ai
  maxConcurrency: 8
  eager: default
mcp:
  discoveryMode: true
symbolPreset: nerd
hideThinkingBlock: false
CONFIG
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
    echo "    ./administrator.sh setup"
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
    echo "  Next: ./administrator.sh setup"
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

cmd_setup() {
    require_cluster

    # Fetch credentials if not already configured
    gcloud container clusters get-credentials "${CLUSTER_NAME}" \
        --zone="${ZONE}" --project="${GCP_PROJECT}" >/dev/null 2>&1

    # 1. Render + apply ClusterSecretStore (detect ESO API version)
    info "Detecting ESO API version…"
    local eso_ver
    eso_ver=$(eso_api_version)
    info "ESO API version: ${eso_ver}"

    info "Applying ClusterSecretStore omp-gsm…"
    GCP_PROJECT="${GCP_PROJECT}" \
    ZONE="${ZONE}" \
    CLUSTER_NAME="${CLUSTER_NAME}" \
        envsubst < "${SCRIPT_DIR}/k8s/clustersecretstore.yaml" \
        | sed "s|external-secrets.io/v1\b|${eso_ver}|g" \
        | kubectl apply -f -

    # 2. Create/patch the master omp-config ConfigMap in omp-system
    info "Creating/updating omp-config ConfigMap in ${SESSION_NS}…"
    local config_yml
    config_yml=$(_base_config_yml)

    kubectl create configmap omp-config \
        --namespace="${SESSION_NS}" \
        --from-literal="config.yml=${config_yml}" \
        --dry-run=client -o yaml \
        | kubectl apply -f -

    echo ""
    echo "SETUP_OK"
    echo "  ClusterSecretStore: omp-gsm (${eso_ver})"
    echo "  ConfigMap omp-config in ${SESSION_NS}"
    echo ""
    echo "  Vault:    printf '%s' \"\$VAL\" | ./administrator.sh vault-add services/my/key"
    echo "  Tune:     ./administrator.sh tune [--memory] [--thinking]"
    echo "  Sessions: see the manager skill for direct kubectl session management"
}

cmd_tune() {
    local do_memory=false do_thinking=false
    if [[ $# -eq 0 ]]; then
        do_memory=true; do_thinking=true
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --memory)   do_memory=true; shift ;;
            --thinking) do_thinking=true; shift ;;
            *) die "Unknown tune option: $1 (use --memory and/or --thinking)" ;;
        esac
    done

    require_cluster

    # Read the current config, patch it, and re-apply.
    local current_config
    current_config=$(kctl get configmap omp-config -n "${SESSION_NS}" \
                     -o jsonpath='{.data.config\.yml}' 2>/dev/null || echo "")
    [[ -n "${current_config}" ]] || current_config=$(_base_config_yml)

    local patched_config="${current_config}"

    if [[ "${do_memory}" == true ]]; then
        info "Adding mnemopi long-term memory tuning…"
        patched_config="${patched_config}
memory:
  backend: mnemopi
mnemopi:
  scoping: per-project-tagged
  noEmbeddings: true
  llmMode: smol
providers:
  memoryModel: qwen3-1.7b
memories:
  minRolloutIdleHours: 6
  maxRolloutAgeDays: 30
  summaryInjectionTokenLimit: 5000"
        ok "memory.backend=mnemopi"
    fi

    if [[ "${do_thinking}" == true ]]; then
        info "Adding automatic thinking-level tuning…"
        patched_config="${patched_config}
defaultThinkingLevel: auto
providers:
  autoThinkingModel: qwen3-1.7b"
        ok "defaultThinkingLevel=auto"
    fi

    kubectl create configmap omp-config \
        --namespace="${SESSION_NS}" \
        --from-literal="config.yml=${patched_config}" \
        --dry-run=client -o yaml \
        | kctl apply -f -

    echo ""
    echo "TUNE_OK"
    echo "  Note: running pods pick up the new config on next restart."
}

cmd_vault_add() {
    local entry="${1:-}"
    [[ -n "${entry}" ]] || die "Usage: ./administrator.sh vault-add ENTRY   (value on stdin)"
    valid_token "${entry}" || die "Invalid entry name: ${entry}"

    # Derive GSM secret id and subtree label from the entry path.
    local subtree="${entry%%/*}"
    local gsm_id; gsm_id=$(printf '%s' "${entry}" | tr '/' '-')
    local sublabel; sublabel=$(printf '%s' "${subtree}" | tr '/' '-')

    # Read value from stdin; never echo it.
    local value
    value=$(cat)
    [[ -n "${value}" ]] || die "Empty value on stdin for entry: ${entry}"

    # Create the GSM secret if it doesn't exist yet.
    if ! gcloud secrets describe "${gsm_id}" --project="${GCP_PROJECT}" >/dev/null 2>&1; then
        info "Creating GSM secret '${gsm_id}'…"
        gcloud secrets create "${gsm_id}" \
            --project="${GCP_PROJECT}" \
            --replication-policy=automatic \
            --labels="omp_vault=true,omp_subtree=${sublabel}" \
            --quiet
    fi

    # Add a new version with the value piped via --data-file=- (never in argv).
    info "Adding new version for '${gsm_id}'…"
    printf '%s' "${value}" \
        | gcloud secrets versions add "${gsm_id}" \
            --project="${GCP_PROJECT}" \
            --data-file=- \
            --quiet

    ok "ADDED ${entry}"
}

cmd_vault_ls() {
    local subtree="${1:-}"
    [[ -z "${subtree}" ]] || valid_token "${subtree}" || die "Invalid subtree: ${subtree}"

    local filter="labels.omp_vault=true"
    if [[ -n "${subtree}" ]]; then
        local sublabel; sublabel=$(printf '%s' "${subtree}" | tr '/' '-')
        filter+=" AND labels.omp_subtree=${sublabel}"
    fi

    gcloud secrets list \
        --project="${GCP_PROJECT}" \
        --filter="${filter}" \
        --format="value(name)"
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
    setup)          cmd_setup "$@" ;;
    tune)           cmd_tune "$@" ;;
    vault-add)      cmd_vault_add "$@" ;;
    vault-ls)       cmd_vault_ls "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown subcommand: ${SUBCOMMAND}" >&2
        echo "Run './administrator.sh help' for usage." >&2
        exit 1
        ;;
esac
