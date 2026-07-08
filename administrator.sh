#!/usr/bin/env bash
# administrator.sh — administrator role: credential vault, teams, status, and local-session
# transfer. Cluster provisioning/config is via Terraform (infra/); sessions via kubectl + ompctl.
#
# Usage:
#   ./administrator.sh <subcommand> [args...]
#
# Subcommands:
#   Provisioning/destroy is via Terraform (cd infra && terraform apply|destroy); platform config/tuning via infra/terraform.tfvars + terraform apply. Session auth/port-forward/lifecycle are via ompctl. See the administrator + manager skills.
#   credentials              Fetch kubectl credentials for the cluster.
#   status                   Cluster summary + node + session list.
#   vault-add ENTRY          Insert a credential into GCP Secret Manager (prompted
#                            interactively, never echoed).
#                            Bare key (no /): auto-scoped to users/<gcloud-user>/<key>
#                            Full path: shared/<key>  or  users/<name>/<key>
#   vault-ls [SUBTREE]       List vault entry names (never values). No arg: shows
#                            shared/ + users/<gcloud-user>/ entries for current user.
#   Personal credentials     Store personal credentials via 'vault-add users/<name>/<key>'
#                            (hidden prompt → GSM). Reference in sessions with
#                            spec.subtrees: ["users/<name>"].
#   team-add <team>          Idempotent: create omp-team-<team> namespace, Session
#                            CRUD Role+RoleBinding for omp-team-<team>@<domain> group,
#                            and grant roles/container.clusterViewer IAM to the group.
#   team-ls                  List all team namespaces and their bound groups.
#   team-rm <team>           Prompt, then delete omp-team-<team> namespace and remove
#                            IAM binding. Warns if session namespaces still exist.
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
#   CLUSTER_NAME       (default: omp-cluster)
#   ADMIN_GCP_ACCOUNT  (default: current gcloud account)
#   OMP_GROUP_DOMAIN   (default: mirantis.com) — Google Workspace domain for RBAC groups
#   SUBTREE            (default: shared) — vault subtree used by vault-ls when unset
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
ADMIN_GCP_ACCOUNT="${ADMIN_GCP_ACCOUNT:-$(gcloud config get-value account 2>/dev/null)}"
OMP_GROUP_DOMAIN="${OMP_GROUP_DOMAIN:-mirantis.com}"

SUBTREE="${SUBTREE:-shared}"
SESSION_NS="omp-system"

# GCP service account emails
SA_ESO="omp-eso@${GCP_PROJECT}.iam.gserviceaccount.com"
SA_OPERATOR="omp-operator@${GCP_PROJECT}.iam.gserviceaccount.com"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Validate a session/subtree token (no shell metacharacters → safe to interpolate).
valid_token() { [[ "$1" =~ ^[A-Za-z0-9_/-]+$ ]]; }

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
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

cmd_vault_add() {
    local entry="${1:-}"
    [[ -n "${entry}" ]] || die "Usage: ./administrator.sh vault-add ENTRY
  Bare key (no /): auto-scoped to users/<gcloud-user>/<key>
  Full path:       shared/<key>  or  users/<name>/<key>"
    valid_token "${entry}" || die "Invalid entry name: ${entry}"

    # If no '/' in entry, auto-scope to the current gcloud user.
    local gcloud_user="${ADMIN_GCP_ACCOUNT%%@*}"
    if [[ "${entry}" != */* ]]; then
        entry="users/${gcloud_user}/${entry}"
        info "Auto-scoped to ${entry} (current gcloud user: ${gcloud_user})"
    fi

    # Derive GSM secret id and subtree label from the entry path.
    local subtree="${entry%/*}"
    local gsm_id; gsm_id=$(printf '%s' "${entry}" | tr '/' '-')
    local sublabel; sublabel=$(printf '%s' "${subtree}" | tr '/' '-')

    # Read value: interactively (hidden) when on a terminal, from pipe when not.
    local value
    if [[ -t 0 ]]; then
        read -rs -p "[admin] Value for '${entry}' (hidden): " value
        echo "" >&2
    else
        value=$(cat)
    fi
    [[ -n "${value}" ]] || die "Empty value for entry: ${entry}"

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

    ok "ADDED ${entry}  →  env var: $(printf '%s' "${entry##*/}" | tr 'a-z-' 'A-Z_' | tr -dc 'A-Z0-9_')"
}

cmd_vault_ls() {
    local subtree="${1:-}"
    [[ -z "${subtree}" ]] || valid_token "${subtree}" || die "Invalid subtree: ${subtree}"

    local gcloud_user="${ADMIN_GCP_ACCOUNT%%@*}"

    if [[ -z "${subtree}" ]]; then
        # Default: show shared/ and current user's personal entries
        info "Vault entries for user '${gcloud_user}' (shared + personal):"
        local user_label="users-${gcloud_user}"
        gcloud secrets list \
            --project="${GCP_PROJECT}" \
            --filter="labels.omp_vault=true AND (labels.omp_subtree=shared OR labels.omp_subtree=${user_label})" \
            --format="table(name,labels.omp_subtree)"
        info "Run 'vault-ls <subtree>' to list a specific subtree."
    else
        local sublabel; sublabel=$(printf '%s' "${subtree}" | tr '/' '-')
        gcloud secrets list \
            --project="${GCP_PROJECT}" \
            --filter="labels.omp_vault=true AND labels.omp_subtree=${sublabel}" \
            --format="table(name,labels.omp_subtree)"
    fi
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

    # Derive pod namespace and CR namespace from session status.
    local ns cr_ns
    for cr_ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' \
                   | tr ' ' '\n' | grep -E '^omp-system$|^omp-team-'); do
        ns=$(kubectl get session "${session_name}" -n "${cr_ns}" \
             -o jsonpath='{.status.namespace}' 2>/dev/null || true)
        [[ -n "${ns}" ]] && break
    done
    [[ -n "${ns}" ]] || die "Session '${session_name}' not found or has no status.namespace yet"
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
    if [[ "${local_encoded}" != "${pod_encoded}" ]]; then
        info "Encodings differ — setting RESUME_SESSION_ID in spec.env…"
        kubectl patch session "${session_name}" -n "${cr_ns}" \
            --type=merge -p "{\"spec\":{\"env\":{\"RESUME_SESSION_ID\":\"${session_id}\"}}}"
        ok "RESUME_SESSION_ID set."
        info "After the session resumes, clear it with:"
        info "  kubectl patch session ${session_name} -n ${cr_ns} --type=merge -p '{\"spec\":{\"env\":{\"RESUME_SESSION_ID\":null}}}'"
    fi

    # Restart the pod so omp picks up the transferred session.
    info "Restarting pod to resume transferred session…"
    kubectl patch session "${session_name}" -n "${cr_ns}" \
        --type=merge -p "{\"spec\":{\"image\":null},\"metadata\":{\"annotations\":{\"omp.mirantis.io/restartedAt\":\"$(date +%s)\"}}}"

    echo ""
    echo "SESSION_TRANSFER_OK"
    echo "  Session : ${session_id}"
    echo "  Pod     : ${ns}"
    echo ""
    echo "  Wait for Hosting, then get the collab link:"
    echo "    kubectl get session ${session_name} -n ${cr_ns} -o jsonpath='{.status.joinLink}'"
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

    info "Granting roles/secretmanager.viewer to group ${group} (list vault entry names, never values)…"
    gcloud projects add-iam-policy-binding "${GCP_PROJECT}" \
        --member="group:${group}" \
        --role="roles/secretmanager.viewer" \
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

    info "Removing roles/secretmanager.viewer IAM binding for group ${group}…"
    gcloud projects remove-iam-policy-binding "${GCP_PROJECT}" \
        --member="group:${group}" \
        --role="roles/secretmanager.viewer" \
        --quiet || warn "IAM binding removal failed (may not exist)"

    ok "TEAM_RM_OK: ${team}"
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
    credentials)    cmd_credentials "$@" ;;
    status)         cmd_status "$@" ;;
    vault-add)      cmd_vault_add "$@" ;;
    vault-ls)       cmd_vault_ls "$@" ;;
    team-add)         cmd_team_add "$@" ;;
    team-ls)          cmd_team_ls "$@" ;;
    team-rm)          cmd_team_rm "$@" ;;
    session-transfer)   cmd_session_transfer "$@" ;;
    help|--help|-h)  cmd_help ;;
    *)
        echo "Unknown subcommand: ${SUBCOMMAND}" >&2
        echo "Run './administrator.sh help' for usage." >&2
        exit 1
        ;;
esac
