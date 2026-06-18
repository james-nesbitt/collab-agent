#!/usr/bin/env bash
# manager.sh — manager role: GSM vault + omp platform config + Session lifecycle
# on the GKE cluster.
#
# Usage:
#   ./manager.sh <subcommand> [args...]
#
# Platform config (global, idempotent):
#   setup                    Configure the ESO ClusterSecretStore, create/update the
#                            master omp-config ConfigMap in omp-system (secrets.enabled,
#                            modelRoles, portable tuning), and print SETUP_OK.
#   vault-add ENTRY          Insert a credential into GCP Secret Manager (value read
#                            from stdin, never echoed). Entry format: subtree/key/...
#                            e.g.  printf '%s' "$TOK" | ./manager.sh vault-add \
#                            services/github/token
#   vault-ls [SUBTREE]       List vault entry NAMES only (no values).
#   tune [--memory] [--thinking]
#                            Patch the master omp-config ConfigMap with opt-in tuning:
#                            mnemopi long-term memory (--memory) and/or automatic
#                            thinking-level selection (--thinking). No flag = both.
#                            New sessions pick it up; running pods on next restart.
#
# Session lifecycle:
#   new NAME [--subtree SUB]...
#                            Apply a Session CR in omp-system. Default subtree:
#                            services. --subtree is repeatable. Waits for Hosting.
#   login NAME               Open an interactive omp auth login in the session pod.
#   attach [NAME]            Attach to the session's tmux (most recent if omitted).
#   list | ls                List Session CRs.
#   kill NAME                Delete the Session CR (operator GCs the namespace + PVC).
#   collab [NAME] [view]     Print the collab join link from status.joinLink.
#   help                     Show this help
#
# For cluster lifecycle (provision/bootstrap/destroy), see ./administrator.sh.
#
# Configuration (override via environment):
#   GCP_PROJECT    (default: tools-348616)
#   ZONE           (default: europe-west1-b)
#   CLUSTER_NAME   (default: omp-cluster)
#   SUBTREE        (default: services) — vault subtree injected by 'new'
set -euo pipefail

# ---------------------------------------------------------------------------
# Shared config + helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="manager"
[[ -f "${SCRIPT_DIR}/lib/common.sh" ]] || { echo "[manager] ERROR: lib/common.sh not found" >&2; exit 1; }
. "${SCRIPT_DIR}/lib/common.sh"

# Default vault subtree injected by 'new'.
SUBTREE="${SUBTREE:-services}"

# Session CRs live in omp-system.
SESSION_NS="omp-system"

# ---------------------------------------------------------------------------
# Manager-specific helpers
# ---------------------------------------------------------------------------

# Validate a session/subtree token (no shell metacharacters → safe to interpolate).
valid_token() { [[ "$1" =~ ^[A-Za-z0-9_/-]+$ ]]; }
# Validate a session name (stricter: no '/', safe for namespace names and kubectl targets).
valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

# Resolve a session name: echo $1, or the most-recently-created Session CR.
resolve_session() {
    local name="${1:-}"
    if [[ -z "${name}" ]]; then
        name=$(kctl get sessions -n "${SESSION_NS}" \
               --sort-by=.metadata.creationTimestamp \
               -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null | tr -d '[:space:]')
        [[ -n "${name}" ]] || die "No sessions found. Run: ./manager.sh new NAME"
    fi
    echo "${name}"
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

# Build the omp config.yml content (base tuning block).
_base_config_yml() {
    cat <<'CONFIG'
# omp platform config — managed by manager.sh setup/tune
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
# Platform config subcommands
# ---------------------------------------------------------------------------
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
    echo "  Next: ./manager.sh new work"
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
    [[ -n "${entry}" ]] || die "Usage: ./manager.sh vault-add ENTRY   (value on stdin)"
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

# ---------------------------------------------------------------------------
# Session lifecycle subcommands
# ---------------------------------------------------------------------------
cmd_list() {
    require_cluster
    info "Sessions in ${SESSION_NS}:"
    kctl get sessions -n "${SESSION_NS}" 2>/dev/null || echo "  (no sessions)"
}

cmd_new() {
    local name=""
    local -a subtrees=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subtree) subtrees+=("${2:?--subtree needs a value}"); shift 2 ;;
            *) [[ -z "${name}" ]] && name="$1"; shift ;;
        esac
    done
    [[ ${#subtrees[@]} -gt 0 ]] || subtrees=("${SUBTREE}")
    [[ -n "${name}" ]] || die "Usage: ./manager.sh new NAME [--subtree SUB]..."
    valid_name "${name}" || die "Invalid session name: ${name}"
    local s
    for s in "${subtrees[@]}"; do valid_token "${s}" || die "Invalid subtree: ${s}"; done

    require_cluster

    # Build subtrees YAML array for the Session spec
    local subtrees_yaml="["
    local first=true
    for s in "${subtrees[@]}"; do
        [[ "${first}" == true ]] || subtrees_yaml+=", "
        subtrees_yaml+="\"${s}\""
        first=false
    done
    subtrees_yaml+="]"

    info "Applying Session CR '${name}' (subtrees: ${subtrees[*]})…"
    kubectl apply -f - <<EOF
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: ${name}
  namespace: ${SESSION_NS}
spec:
  subtrees: ${subtrees_yaml}
  view: false
EOF

    # Wait for Hosting (or Running on slow collab capture)
    info "Waiting for session '${name}' to reach Hosting…"
    if kubectl wait \
        --for=jsonpath='{.status.phase}'=Hosting \
        session/"${name}" \
        -n "${SESSION_NS}" \
        --timeout=180s 2>/dev/null; then
        ok "Session '${name}' is Hosting."
    elif kubectl wait \
        --for=jsonpath='{.status.phase}'=Running \
        session/"${name}" \
        -n "${SESSION_NS}" \
        --timeout=30s 2>/dev/null; then
        warn "Session '${name}' is Running (collab link not yet captured)."
    else
        local phase
        phase=$(kctl get session "${name}" -n "${SESSION_NS}" \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        die "Session '${name}' stuck in phase '${phase}'. Check: kubectl describe session/${name} -n ${SESSION_NS}"
    fi

    echo ""
    echo "  Attach : ./manager.sh attach ${name}"
    echo "  Login  : ./manager.sh login ${name}   # Anthropic OAuth (persists on PVC)"
    echo "  Collab : ./manager.sh collab ${name}"
    echo ""
    echo "  Token-based providers: store the key with vault-add model/<provider>/api-key"
    echo "  and launch with --subtree model (injected as e.g. ANTHROPIC_API_KEY)."
}

cmd_login() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: ./manager.sh login NAME"
    valid_name "${name}" || die "Invalid session name: ${name}"
    require_cluster
    info "Opening interactive auth login in session '${name}'…"
    info "Note: token-based providers (e.g. ANTHROPIC_API_KEY) need no login;"
    info "      use: printf '%s' \"\$KEY\" | ./manager.sh vault-add model/anthropic/api-key"
    kubectl exec -it -n "omp-session-${name}" omp -- bash -lc 'omp auth login'
}

cmd_attach() {
    local name
    name="$(resolve_session "${1:-}")"
    valid_name "${name}" || die "Refusing to attach: unsafe session name: ${name}"
    require_cluster
    info "Attaching to session '${name}'…"
    kubectl exec -it -n "omp-session-${name}" omp -- tmux attach -t omp
}

cmd_kill() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: ./manager.sh kill NAME"
    valid_name "${name}" || die "Invalid session name: ${name}"
    require_cluster
    info "Deleting Session CR '${name}' (operator will GC namespace + PVC)…"
    kctl delete session "${name}" -n "${SESSION_NS}"
    ok "Killed."
}

cmd_collab() {
    local raw_name="${1:-}"
    local name; name="$(resolve_session "${raw_name}")"
    valid_name "${name}" || die "Refusing to act on unsafe session name: ${name}"
    local mode="${2:-}"
    require_cluster

    local link_field="joinLink"
    [[ "${mode}" == "view" ]] && link_field="viewLink"

    local link
    link=$(kctl get session "${name}" -n "${SESSION_NS}" \
           -o jsonpath="{.status.${link_field}}" 2>/dev/null | tr -d '[:space:]')

    if [[ -z "${link}" ]]; then
        info "Link not yet captured; triggering re-capture…"
        local ts; ts=$(date +%s)
        kctl annotate session "${name}" -n "${SESSION_NS}" \
            "omp.mirantis.io/recapture=${ts}" --overwrite >/dev/null
        # Wait up to 30s for the operator to refresh
        local i=0
        while [[ ${i} -lt 6 ]]; do
            sleep 5
            link=$(kctl get session "${name}" -n "${SESSION_NS}" \
                   -o jsonpath="{.status.${link_field}}" 2>/dev/null | tr -d '[:space:]')
            [[ -n "${link}" ]] && break
            (( i++ )) || true
        done
        [[ -n "${link}" ]] || die "No ${link_field} available for session '${name}'."
    fi

    echo "${link}"
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
    setup)          cmd_setup "$@" ;;
    tune)           cmd_tune "$@" ;;
    vault-add)      cmd_vault_add "$@" ;;
    vault-ls)       cmd_vault_ls "$@" ;;
    new)            cmd_new "$@" ;;
    login)          cmd_login "$@" ;;
    attach|a)       cmd_attach "$@" ;;
    list|ls)        cmd_list "$@" ;;
    kill)           cmd_kill "$@" ;;
    collab)         cmd_collab "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown subcommand: ${SUBCOMMAND}" >&2
        echo "Run './manager.sh help' for usage." >&2
        exit 1
        ;;
esac
