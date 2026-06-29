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
#   team-add <team>          Idempotent: create omp-team-<team> namespace, Session
#                            CRUD Role+RoleBinding for omp-team-<team>@<domain> group,
#                            and grant roles/container.clusterViewer IAM to the group.
#   team-ls                  List all team namespaces and their bound groups.
#   team-rm <team>           Prompt, then delete omp-team-<team> namespace and remove
#                            IAM binding. Warns if session namespaces still exist.
#   pull-secret              Update the GHCR image pull secret from a GitHub PAT on stdin.
#                            Requires read:packages scope. Propagates to all session namespaces.
#                            printf '%s' "$PAT" | ./administrator.sh pull-secret
#   auth NAME PROVIDER [CONTAINER]
#                            Interactive provider login INSIDE a session pod (device code
#                            or token on stdin). Providers: anthropic gcloud aws
#                            aws-configure az gh. Credentials persist on the session PVC.
#   port-forward NAME LOCAL_PORT [REMOTE_PORT]
#                            Forward a session pod port to localhost (for browser-redirect
#                            OAuth, e.g. aws configure sso).
#   session-transfer NAME [LOCAL_DIR] [SESSION_ID]
#                            Copy a local omp session onto a GKE session pod's PVC so the
#                            conversation resumes there.
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
#   OMP_IMAGE_TAG      (default: latest)
#   OMP_GROUP_DOMAIN   (default: mirantis.com) — Google Workspace domain for RBAC groups
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
# Session image tag defaults to latest independently of the operator tag so that
# restarted sessions always pick up the newest omp build.
OMP_SESSION_IMAGE_TAG="${OMP_SESSION_IMAGE_TAG:-latest}"
OMP_GROUP_DOMAIN="${OMP_GROUP_DOMAIN:-mirantis.com}"

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
    OMP_SESSION_IMAGE_TAG="${OMP_SESSION_IMAGE_TAG}" \
    OMP_GROUP_DOMAIN="${OMP_GROUP_DOMAIN}" \
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
  default: google/gemini-3.1-pro-preview
  plan: google/gemini-3.1-pro-preview
  slow: google/gemini-1.5-pro
  smol: google/gemini-1.5-flash
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
        warn "Cluster '${CLUSTER_NAME}' already exists — enabling Groups-for-RBAC if not set."
        gcloud container clusters update "${CLUSTER_NAME}" \
            --zone="${ZONE}" \
            --project="${GCP_PROJECT}" \
            --security-group="gke-security-groups@${OMP_GROUP_DOMAIN}" \
            --quiet
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
            --security-group="gke-security-groups@${OMP_GROUP_DOMAIN}" \
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

    # 4. IAM roles — operator gets project-level viewer (metadata only);
    #    ESO gets per-secret secretAccessor granted by vault-add (not project-wide).
    info "Binding IAM roles…"
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

    # 6. Grant cluster access: admin user (break-glass) + admin group (GKE Groups-for-RBAC)
    info "Granting container.admin to ${ADMIN_GCP_ACCOUNT}…"
    gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
        --member="user:${ADMIN_GCP_ACCOUNT}" \
        --role="roles/container.admin" \
        --quiet
    info "Granting container.admin to group omp-admins@${OMP_GROUP_DOMAIN}…"
    gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
        --member="group:omp-admins@${OMP_GROUP_DOMAIN}" \
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
    # 1b. RBAC: bind omp-admins group to cluster-admin (additive — preserves user binding above)
    info "Binding group omp-admins@${OMP_GROUP_DOMAIN} to cluster-admin…"
    kubectl create clusterrolebinding omp-admins-group \
        --clusterrole=cluster-admin \
        --group="omp-admins@${OMP_GROUP_DOMAIN}" \
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
    local subtree="${entry%/*}"
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

    # Grant ESO SA secretAccessor on this specific secret only (not project-wide).
    info "Granting ESO secretAccessor on '${gsm_id}'…"
    gcloud secrets add-iam-policy-binding "${gsm_id}" \
        --project="${GCP_PROJECT}" \
        --member="serviceAccount:${SA_ESO}" \
        --role="roles/secretmanager.secretAccessor" \
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

cmd_auth() {
    # auth NAME PROVIDER [CONTAINER]
    # Execute an interactive auth flow inside a running session pod.
    # Credentials are stored under $HOME on the PVC and survive pod restarts.
    #
    # Providers:
    #   anthropic   omp auth-broker login anthropic  (device code)
    #   gcloud      gcloud auth login --no-browser    (device code)
    #   aws         aws sso login --no-browser        (device code; profile prompted)
    #   az          az login --use-device-code        (device code)
    #   gh TOKEN    gh auth login --with-token        (token on stdin)
    local name="${1:-}"
    local provider="${2:-}"
    local container="${3:-omp}"
    [[ -n "${name}" ]]     || die "Usage: ./administrator.sh auth NAME PROVIDER [CONTAINER]"
    [[ -n "${provider}" ]] || die "Usage: ./administrator.sh auth NAME PROVIDER [CONTAINER]"
    require_cluster

    # Derive pod namespace from session status — works for admin and team sessions.
    # Iterates all namespaces that could hold a Session CR (omp-system + omp-team-*),
    # avoiding unreliable cross-namespace jsonpath ?() filtering in kubectl.
    local ns cr_ns
    for cr_ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' \
                   | tr ' ' '\n' | grep -E '^omp-system$|^omp-team-'); do
        ns=$(kubectl get session "${name}" -n "${cr_ns}" \
             -o jsonpath='{.status.namespace}' 2>/dev/null || true)
        [[ -n "${ns}" ]] && break
    done
    [[ -n "${ns}" ]] || die "Session '${name}' not found or has no status.namespace yet (still provisioning?)"
    local kctl_exec="kubectl exec -it -n ${ns} -c ${container} omp -- bash -lc"

    case "${provider}" in
        anthropic)
            info "Authenticating Anthropic in session '${name}' (device code — visit the URL in your browser)…"
            kubectl exec -it -n "${ns}" -c "${container}" omp -- bash -lc \
                'omp auth-broker login anthropic'
            ;;
        gcloud)
            info "Authenticating gcloud in session '${name}' (device code — visit the URL in your browser)…"
            kubectl exec -it -n "${ns}" -c "${container}" omp -- bash -lc \
                'gcloud auth login --no-browser'
            ;;
        aws)
            info "Authenticating AWS SSO in session '${name}' (device code — visit the URL in your browser)…"
            info "If no SSO profile is configured yet, run: ./administrator.sh auth ${name} aws-configure"
            kubectl exec -it -n "${ns}" -c "${container}" omp -- bash -lc \
                'aws sso login --no-browser'
            ;;
        aws-configure)
            info "Running 'aws configure sso' wizard in session '${name}'…"
            info "NOTE: the wizard opens a browser URL — use a port-forward if your terminal can't open one."
            kubectl exec -it -n "${ns}" -c "${container}" omp -- bash -lc \
                'aws configure sso'
            ;;
        az)
            info "Authenticating Azure CLI in session '${name}' (device code — visit the URL in your browser)…"
            kubectl exec -it -n "${ns}" -c "${container}" omp -- bash -lc \
                'az login --use-device-code'
            ;;
        gh)
            # Token piped on stdin; never appears in argv
            info "Authenticating GitHub CLI in session '${name}' (token on stdin)…"
            info "Paste your GitHub PAT and press Ctrl-D:"
            kubectl exec -i -n "${ns}" -c "${container}" omp -- bash -lc \
                'gh auth login --with-token'
            ;;
        *)
            die "Unknown provider '${provider}'. Valid: anthropic gcloud aws aws-configure az gh"
            ;;
    esac
}

cmd_port_forward() {
    # port-forward NAME LOCAL_PORT [REMOTE_PORT]
    # Forward a port from the session pod to localhost.
    # Useful for browser-redirect OAuth flows (e.g. aws configure sso).
    # Example:
    #   Terminal 1: ./administrator.sh port-forward work 8400
    #   Terminal 2: kubectl exec -it -n omp-session-work omp -- bash -lc \
    #                 'aws configure sso --redirect-url http://localhost:8400/callback'
    local name="${1:-}"
    local local_port="${2:-}"
    local remote_port="${3:-${local_port}}"
    local ns cr_ns
    for cr_ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' \
                   | tr ' ' '\n' | grep -E '^omp-system$|^omp-team-'); do
        ns=$(kubectl get session "${name}" -n "${cr_ns}" \
             -o jsonpath='{.status.namespace}' 2>/dev/null || true)
        [[ -n "${ns}" ]] && break
    done
    [[ -n "${ns}" ]] || die "Session '${name}' not found or has no status.namespace yet (still provisioning?)"
    info "Forwarding localhost:${local_port} → pod omp in ${ns}:${remote_port}"
    info "Press Ctrl-C to stop."
    kubectl port-forward -n "${ns}" pod/omp "${local_port}:${remote_port}"
}

cmd_session_transfer() {
    # session-transfer NAME [LOCAL_DIR] [SESSION_ID]
    # Copy a local omp session to a running GKE session pod so the conversation
    # resumes on the next pod start.
    #
    # NAME        — GKE session name (e.g. prodeng-3468)
    # LOCAL_DIR   — local working directory the session was running in
    #               (default: current directory)
    # SESSION_ID  — specific session UUID to transfer (default: most recent for LOCAL_DIR)
    #
    # The session .jsonl is copied to the pod PVC via kubectl cp.
    # If the local cwd encoding differs from the pod encoding, RESUME_SESSION_ID is set
    # in spec.env so the entrypoint uses --resume instead of -c.
    # The pod is restarted to pick up the session (unless the env flag is the only change
    # and you want to defer the restart).
    local session_name="${1:-}"
    local local_dir="${2:-$(pwd)}"
    local explicit_id="${3:-}"
    [[ -n "${session_name}" ]] || die "Usage: ./administrator.sh session-transfer NAME [LOCAL_DIR] [SESSION_ID]"
    require_cluster

    local local_home="${HOME}"
    local_dir=$(realpath "${local_dir}") || die "LOCAL_DIR '${local_dir}' not found"

    # Locate the local omp agent directory (prefer newer ~/.local/share/omp).
    local agent_dir=""
    if [[ -d "${local_home}/.local/share/omp" ]]; then
        agent_dir="${local_home}/.local/share/omp"
    elif [[ -d "${local_home}/.omp/agent" ]]; then
        agent_dir="${local_home}/.omp/agent"
    else
        die "No local omp agent dir found (looked for ~/.local/share/omp and ~/.omp/agent)"
    fi

    # Compute the cwd-relative encoding for LOCAL_DIR.
    local rel
    rel=$(realpath --relative-to="${local_home}" "${local_dir}" 2>/dev/null) \
        || die "LOCAL_DIR '${local_dir}' is not under HOME (${local_home})"
    local local_encoded="-${rel//\//-}"

    # Find the session .jsonl to transfer.
    local session_dir="${agent_dir}/sessions/${local_encoded}"
    [[ -d "${session_dir}" ]] \
        || die "No sessions for '${local_dir}' (looked in ${session_dir})"

    local jsonl=""
    if [[ -n "${explicit_id}" ]]; then
        jsonl=$(ls "${session_dir}"/*"${explicit_id}"*.jsonl 2>/dev/null | head -1)
        [[ -n "${jsonl}" ]] || die "Session ID '${explicit_id}' not found in ${session_dir}"
    else
        jsonl=$(ls -t "${session_dir}"/*.jsonl 2>/dev/null | head -1)
        [[ -n "${jsonl}" ]] || die "No .jsonl files in ${session_dir}"
    fi

    # Extract session ID from the filename: strip timestamp prefix up to first _.
    local filename
    filename=$(basename "${jsonl}" .jsonl)
    local session_id="${filename#*_}"

    # Pod-side paths.
    local ns="omp-session-${session_name}"
    local pod_home="/home/omp"
    local pod_agent="${pod_home}/.omp/agent"
    local pod_encoded="-${session_name}"          # pod cwd is always ~/SESSION_NAME
    local pod_session_dir="${pod_agent}/sessions/${pod_encoded}"

    info "Session to transfer  : ${session_id}"
    info "Source               : ${jsonl}"
    info "Destination          : ${ns}/omp:${pod_session_dir}/$(basename "${jsonl}")"
    info "Local encoding       : ${local_encoded}"
    info "Pod encoding         : ${pod_encoded}"

    # Create the target directory on the pod (idempotent).
    kubectl exec -n "${ns}" omp -- mkdir -p "${pod_session_dir}"

    # Copy the session file to the pod PVC via kubectl cp (goes through the running pod).
    kubectl cp "${jsonl}" "${ns}/omp:${pod_session_dir}/$(basename "${jsonl}")"
    ok "Session file copied."

    # If encodings differ, inject RESUME_SESSION_ID so the entrypoint uses --resume=<id>.
    # (When encodings match, -c will find the session automatically; no env patch needed.)
    if [[ "${local_encoded}" != "${pod_encoded}" ]]; then
        info "Encodings differ — setting RESUME_SESSION_ID in spec.env…"
        kubectl patch session "${session_name}" -n "${SESSION_NS}" \
            --type=merge -p "{\"spec\":{\"env\":{\"RESUME_SESSION_ID\":\"${session_id}\"}}}"
        ok "RESUME_SESSION_ID set."
        info "After the session resumes, clear it with:"
        info "  kubectl patch session ${session_name} -n ${SESSION_NS} --type=merge -p '{\"spec\":{\"env\":{\"RESUME_SESSION_ID\":null}}}'"
    fi

    # Restart the pod so omp picks up the transferred session.
    info "Restarting pod to resume transferred session…"
    kubectl patch session "${session_name}" -n "${SESSION_NS}" \
        --type=merge -p "{\"spec\":{\"image\":null},\"metadata\":{\"annotations\":{\"omp.mirantis.io/restartedAt\":\"$(date +%s)\"}}}"

    echo ""
    echo "SESSION_TRANSFER_OK"
    echo "  Session : ${session_id}"
    echo "  Pod     : ${ns}"
    echo ""
    echo "  Wait for Hosting, then get the collab link:"
    echo "    kubectl get session ${session_name} -n ${SESSION_NS} -o jsonpath='{.status.joinLink}'"
}

# ---------------------------------------------------------------------------
# Team management subcommands
# ---------------------------------------------------------------------------

# valid_team <slug> — return 0 if team slug is a DNS-label-safe identifier.
valid_team() { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; }

cmd_team_add() {
    local team="${1:-}"
    [[ -n "${team}" ]] || die "Usage: ./administrator.sh team-add <team>"
    valid_team "${team}" || die "Invalid team slug '${team}': must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?\$"
    require_cluster
    local ns="omp-team-${team}"
    local group="omp-team-${team}@${OMP_GROUP_DOMAIN}"

    info "Creating team namespace + RBAC for '${team}' (group: ${group})…"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    omp.mirantis.io/team: "${team}"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: omp-team-sessions
  namespace: ${ns}
rules:
  - apiGroups: ["omp.mirantis.io"]
    resources: ["sessions", "sessions/status"]
    verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: omp-team-sessions
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: omp-team-sessions
subjects:
  - kind: Group
    apiGroup: rbac.authorization.k8s.io
    name: ${group}
EOF

    info "Granting roles/container.clusterViewer to group ${group}…"
    gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
        --member="group:${group}" \
        --role="roles/container.clusterViewer" \
        --quiet

    echo ""
    echo "TEAM_ADD_OK: ${team}"
    echo "  Namespace   : ${ns}"
    echo "  Group       : ${group}"
    echo ""
    echo "  Manual steps (Workspace admin required):"
    echo "    1. Create group ${group} in Google Workspace (admin.google.com)"
    echo "    2. Nest ${group} inside gke-security-groups@${OMP_GROUP_DOMAIN}"
    echo "    3. Add team members to ${group}"
    echo ""
    echo "  Members create sessions with:"
    echo "    spec.team: ${team}    (CR must be in namespace ${ns})"
    echo "  Session pod namespace: omp-session-${team}-<name>"
}

cmd_team_ls() {
    require_cluster
    info "Team namespaces:"
    kubectl get namespaces \
        -l omp.mirantis.io/team \
        -o custom-columns="TEAM:.metadata.labels.omp\.mirantis\.io/team,NAMESPACE:.metadata.name"
    echo ""
    info "Team RBAC subjects (one binding per team):"
    for ns in $(kubectl get namespaces -l omp.mirantis.io/team -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        local subj
        subj=$(kubectl get rolebinding omp-team-sessions -n "${ns}" \
               -o jsonpath='{.subjects[0].name}' 2>/dev/null || echo "(no binding)")
        echo "  ${ns}: ${subj}"
    done
}

cmd_team_rm() {
    local team="${1:-}"
    [[ -n "${team}" ]] || die "Usage: ./administrator.sh team-rm <team>"
    valid_team "${team}" || die "Invalid team slug: ${team}"
    require_cluster
    local ns="omp-team-${team}"
    local group="omp-team-${team}@${OMP_GROUP_DOMAIN}"

    # Warn if session namespaces still exist for this team
    local live_sessions
    live_sessions=$(kubectl get namespaces \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
        | tr ' ' '\n' | grep "^omp-session-${team}-" || true)
    if [[ -n "${live_sessions}" ]]; then
        warn "The following session namespaces still exist for team '${team}':"
        echo "${live_sessions}" | sed 's/^/    /'
        warn "Delete the team's Sessions first, then re-run team-rm."
    fi

    echo ""
    echo "WARNING: This will delete namespace '${ns}' and remove IAM binding for group ${group}."
    read -r -p "Type 'yes' to confirm: " confirm
    [[ "${confirm}" == "yes" ]] || { info "Aborted."; exit 0; }

    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
        info "Deleting namespace ${ns} (cascades Role + RoleBinding)…"
        kubectl delete namespace "${ns}"
    else
        info "Namespace ${ns} not found — skipping."
    fi

    info "Removing roles/container.clusterViewer IAM binding for group ${group}…"
    gcloud projects remove-iam-policy-binding "${GCP_PROJECT}" \
        --member="group:${group}" \
        --role="roles/container.clusterViewer" \
        --quiet || warn "IAM binding removal failed (may not exist)"

    ok "TEAM_RM_OK: ${team}"
}

cmd_pull_secret() {
    # pull-secret — update the GHCR image pull secret from a PAT on stdin.
    # The PAT needs read:packages (and repo for private packages).
    # Updates omp-system and propagates to all running session namespaces.
    require_cluster

    local token
    token=$(cat)
    [[ -n "${token}" ]] || die "No token on stdin. Usage: printf '%s' \"\$PAT\" | ./administrator.sh pull-secret"

    info "Updating ghcr-pull-secret in omp-system…"
    kubectl create secret docker-registry ghcr-pull-secret \
        -n omp-system \
        --docker-server=ghcr.io \
        --docker-username="${ADMIN_GCP_ACCOUNT%%@*}" \
        --docker-password="${token}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Propagate to all running session namespaces (omp-session-*)
    info "Propagating to session namespaces…"
    local updated=0
    for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' \
                | tr ' ' '\n' | grep '^omp-session-'); do
        kubectl create secret docker-registry ghcr-pull-secret \
            -n "${ns}" \
            --docker-server=ghcr.io \
            --docker-username="${ADMIN_GCP_ACCOUNT%%@*}" \
            --docker-password="${token}" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 && updated=$((updated + 1))
    done
    ok "PULL_SECRET_OK — updated omp-system + ${updated} session namespace(s)"
    info "Pods in ImagePullBackOff will recover automatically within ~30s."
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
    pull-secret)      cmd_pull_secret "$@" ;;
    auth)             cmd_auth "$@" ;;
    port-forward)     cmd_port_forward "$@" ;;
    session-transfer) cmd_session_transfer "$@" ;;
    team-add)         cmd_team_add "$@" ;;
    team-ls)          cmd_team_ls "$@" ;;
    team-rm)          cmd_team_rm "$@" ;;
    help|--help|-h)  cmd_help ;;
    *)
        echo "Unknown subcommand: ${SUBCOMMAND}" >&2
        echo "Run './administrator.sh help' for usage." >&2
        exit 1
        ;;
esac
