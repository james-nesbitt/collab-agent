# Access control

Multi-team access to the omp GKE platform is enforced at three independent layers:
GCP IAM (can you reach the cluster?), Kubernetes RBAC (what can you do inside it?),
and the operator's namespace-ownership guard (can your CR create sessions in this namespace?).

## Groups

All group subjects are **Google Groups** resolved via GKE Groups-for-RBAC
(`--security-group=gke-security-groups@<domain>`). GKE only processes groups
that are transitively inside the `gke-security-groups@<domain>` umbrella.

A **Workspace/Cloud-Identity admin** (via admin.google.com or Admin SDK — not scriptable
from this repo) creates and maintains three tiers:

| Group | Who creates it | Purpose |
|---|---|---|
| `gke-security-groups@mirantis.com` | Workspace admin | Required umbrella; members are other groups only |
| `omp-admins@mirantis.com` | Workspace admin | Cluster admins; member of `gke-security-groups@` |
| `omp-team-<team>@mirantis.com` | Workspace admin, one per team | Team members; member of `gke-security-groups@` |

Until the groups exist in Workspace, all RBAC bindings for them are inert for real users
but fully testable via `kubectl auth can-i --as-group=` impersonation.

## GCP IAM tiers

| Principal | IAM role | What it allows |
|---|---|---|
| `user:jnesbitt@mirantis.com` | `roles/container.admin` | Full cluster administration (break-glass) |
| `group:omp-admins@mirantis.com` | `roles/container.admin` | Cluster administration via group |
| `group:omp-team-<team>@mirantis.com` | `roles/container.clusterViewer` | `get-credentials` + cluster Console visibility; all K8s authz is RBAC-gated |

`roles/container.clusterViewer` is sufficient for `get-credentials`. All Kubernetes-level
authorization is handled by RBAC — the IAM role only controls who can obtain credentials.

## Kubernetes RBAC

### Admins

| Binding | Kind | Subject | Scope |
|---|---|---|---|
| `omp-admin` ClusterRoleBinding | `cluster-admin` | `user:jnesbitt@mirantis.com` | cluster-wide (break-glass) |
| `omp-admins-group` ClusterRoleBinding | `cluster-admin` | `group:omp-admins@mirantis.com` | cluster-wide |

### Teams

Each team has:

1. **A team namespace** `omp-team-<team>` — the only namespace where team members can
   create/manage Session CRs.
2. **A Role** `omp-team-sessions` in `omp-team-<team>` — allows `create/get/list/watch/update/patch/delete`
   on `sessions` and `sessions/status` in `omp.mirantis.io`.
3. **A RoleBinding** `omp-team-sessions` → group `omp-team-<team>@mirantis.com`.
4. **Per-session-namespace RBAC** (created by the operator when a Session with `spec.team`
   is reconciled) — a Role `omp-session-user` in `omp-session-<team>-<name>` with
   `pods` read, `pods/exec` create, `pods/log` get. A RoleBinding binds it to
   `group:omp-team-<team>@mirantis.com`. Teams can exec into their own session pods only —
   not secrets, not other teams' pods.

## Namespace model

| Namespace pattern | Created by | Owner |
|---|---|---|
| `omp-system` | bootstrap | operator infra |
| `omp-team-<team>` | `team-add <team>` | team CR home |
| `omp-session-<team>-<name>` | operator (team sessions) | team session |
| `omp-session-<name>` | operator (admin sessions, no `spec.team`) | admin-created session |

## Security boundary

The collab join link stays inherently joinable-by-link; this access control model controls
**who can obtain the link and reach the pod**, not the relay. Specifically:

- `kubectl get sessions -n omp-team-<team>` no longer prints the link (LINK printer column
  removed from CRD). The link is still readable via
  `kubectl get session <name> -n omp-team-<team> -o jsonpath='{.status.joinLink}'` by any
  principal with `get sessions` in that namespace.
- Team members can only `get sessions` in their own `omp-team-<team>` namespace —
  they never see another team's links.
- Teams can never read the `omp-creds` or any credential Secret in session namespaces;
  the RBAC rules explicitly omit `secrets`.

## Team onboarding flow

### Prerequisite (Workspace admin — do this first)

1. Create `omp-team-<team>@mirantis.com` in Google Workspace.
2. Nest it inside `gke-security-groups@mirantis.com`.
3. Add team members to `omp-team-<team>@mirantis.com`.

### Administrator (scriptable, after prerequisite)

```bash
./administrator.sh team-add <team>
```

This is idempotent. It:
1. Creates namespace `omp-team-<team>` with label `omp.mirantis.io/team=<team>`.
2. Creates Role `omp-team-sessions` and RoleBinding → `group:omp-team-<team>@mirantis.com`.
   The Role includes `sessions` CRUD **and** `secrets` CRUD so team members can manage
   their own personal credential Secrets without admin involvement.
3. Grants `roles/container.clusterViewer` IAM — members can `get-credentials`.
4. Grants `roles/secretmanager.viewer` IAM — members can list vault entry names (never values).

### Team member: create a session

```yaml
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: my-session
  namespace: omp-team-<team>      # must match spec.team
spec:
  subtrees: ["shared"]            # platform creds from vault
  team: <team>
  credentialSecrets:              # personal creds from K8s Secrets in this namespace
    - my-creds
```

The operator enforces that `spec.team` matches the CR namespace (`omp-team-<team>`).
A CR with `spec.team: foo` created in `omp-team-bar` is rejected with status `Failed`.

## Self-service session credentials

Team members manage personal credentials via **K8s Secrets in their team namespace** —
no admin or GSM access required.

### Creating and referencing personal credential secrets

```bash
# Create a secret in the team namespace (team member does this themselves)
kubectl create secret generic jnesbitt-creds -n omp-team-<team> \
  --from-literal=ATLASSIAN_TOKEN=xxx \
  --from-literal=ATLASSIAN_EMAIL=jnesbitt@mirantis.com

# Update / rotate
kubectl create secret generic jnesbitt-creds -n omp-team-<team> \
  --from-literal=ATLASSIAN_TOKEN=yyy \
  --dry-run=client -o yaml | kubectl apply -f -
```

Reference one or more secrets in the Session CR:

```yaml
spec:
  subtrees: ["shared"]         # vault creds (OLLAMA_CLOUD_API_KEY etc.)
  credentialSecrets:
    - jnesbitt-creds           # personal creds — injected after vault, override on conflict
    - another-secret           # multiple supported; later entries win
```

The operator copies each named Secret from `omp-team-<team>` into the session pod namespace
and injects it via `envFrom`. Team members can also list, describe, and delete their own
Secrets — RBAC in `omp-team-<team>` grants full secrets CRUD in that namespace only.

Session pod namespaces (`omp-session-<team>-<name>`) do **not** grant team members `secrets`
access — they can exec and view logs but never read the injected credential values directly.

### Listing available vault credentials

Team members have `roles/secretmanager.viewer` IAM — they can list credential names, never values:

```bash
./administrator.sh vault-ls shared           # platform creds available to all sessions
./administrator.sh vault-ls users/jnesbitt   # personal entries for this user
```

## Listing and removing teams

```bash
./administrator.sh team-ls           # list all team namespaces + bound groups
./administrator.sh team-rm <team>    # prompt + delete ns + remove IAM (warns if sessions exist)
```

Delete all team sessions before `team-rm`.

## `OMP_GROUP_DOMAIN`

The default domain is `mirantis.com`. Override for a different Workspace:

```bash
OMP_GROUP_DOMAIN=example.com ./administrator.sh provision
OMP_GROUP_DOMAIN=example.com ./administrator.sh team-add myteam
```

The operator reads `OMP_GROUP_DOMAIN` from its Deployment env (set by `bootstrap` via
`k8s/operator-deploy.yaml`).
