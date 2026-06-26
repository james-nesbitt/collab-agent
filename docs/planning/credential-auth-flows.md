# Credential auth flows for interactive provider logins

## Problem

The GSM → ESO → K8s Secret → envFrom pipeline is the right path for **static credentials** (API keys, long-lived tokens, service account keys stored in advance). It cannot handle:

1. **Interactive OAuth / SSO flows** — `gcloud auth login`, `aws configure sso`, `omp auth-broker login anthropic` — that require a human to visit a URL or complete a device-code exchange at auth time.
2. **Short-lived identity-bound tokens** — credentials specific to the human operator's personal identity (personal Anthropic subscription, personal AWS SSO principal, personal GCP account) rather than shared service credentials.
3. **Post-session token refresh** — tokens that expire while the session is live; a pod restart + re-auth is the current recovery path.

The goal of this effort is to design tooling that makes all three scenarios work without compromising the per-session isolation or the "never echo credentials" security constraints.

---

## Auth flow taxonomy

| Provider | Flow type | Interactive? | Personal identity? | Token lifetime |
|---|---|---|---|---|
| Anthropic (`omp auth-broker login anthropic`) | device code | yes (browser) | yes | ~24 h |
| GCP (`gcloud auth login`) | device code via `--no-browser` | yes (URL+code) | yes (ADC) | ~1 h (access) / long refresh |
| AWS SSO (`aws configure sso` / `aws sso login`) | browser redirect | yes (browser) | yes | 8–12 h |
| GitHub (`gh auth login`) | device code / token paste | yes | yes or service | long-lived PAT |
| Azure (`az login`) | device code | yes | yes or SP | ~1 h (access) / long refresh |

**Service credentials** (GitHub PAT, JIRA token, AWS long-term key, GCP service-account key) → already handled by GSM/ESO. This doc focuses on the personal/interactive flows above.

---

## Constraint: what a pod can do

Session pods have:
- Outbound TCP 443 to internet (relay, auth endpoints reachable). ✓
- No inbound ports (NetworkPolicy deny-all ingress). ✗
- No GCE metadata server (169.254.169.254 blocked). ✗
- No local browser in the container (headless only). ✗
- Interactive stdin available via `kubectl exec -it`. ✓
- Persistent `$HOME` on PVC across pod restarts. ✓

**Device-code flows** (print URL + short code, user visits browser on their own machine) work fully inside the pod via `kubectl exec -it`. Browser-redirect flows (OAuth `response_type=code` that opens `localhost:PORT`) do not work directly but can be proxied via `kubectl port-forward`.

---

## Option A — exec-based interactive auth (no new infrastructure)

Run auth commands inside the pod interactively. Credentials are stored on the PVC by the CLI and persist across restarts.

```bash
# Anthropic — device code (user visits URL on their machine)
kubectl exec -it -n omp-session-NAME omp -- bash -lc \
  'omp auth-broker login anthropic'

# GCP — device code (--no-browser prints URL+code; no browser in pod)
kubectl exec -it -n omp-session-NAME omp -- bash -lc \
  'gcloud auth login --no-browser'

# AWS SSO — device code (aws sso login --no-browser available in v2.15+)
kubectl exec -it -n omp-session-NAME omp -- bash -lc \
  'aws configure sso'     # interactive wizard, then:
  'aws sso login --no-browser --profile PROFILE_NAME'

# GitHub — paste token (non-interactive; avoids browser)
printf '%s' "$MY_GH_PAT" | kubectl exec -i -n omp-session-NAME omp -- \
  bash -lc 'gh auth login --with-token'

# Azure — device code
kubectl exec -it -n omp-session-NAME omp -- bash -lc \
  'az login --use-device-code'
```

**Where credentials land:**
| Provider | On-disk location | Persists on PVC? |
|---|---|---|
| Anthropic (`omp`) | `~/.omp/agent/agent.db` (SQLite) | ✓ |
| GCP (`gcloud`) | `~/.config/gcloud/` | ✓ |
| AWS | `~/.aws/credentials`, `~/.aws/config` | ✓ |
| GitHub (`gh`) | `~/.config/gh/hosts.yml` | ✓ |
| Azure | `~/.azure/` | ✓ |

All of these survive pod restarts because `$HOME` is on the PVC.

**Tradeoffs:**
- Zero new infrastructure; auth is a one-time `kubectl exec` per session.
- Refresh must be manual — when the token expires, exec in and re-auth.
- Requires the operator to have `kubectl exec` access (they already do).
- AWS SSO `--no-browser` requires aws-cli v2.15+; this must be in the image.

**Gap:** AWS SSO's `aws configure sso` still opens a browser on `localhost`. Workaround via port-forward in Option B.

---

## Option B — port-forward for browser-redirect flows

For flows that insist on a local browser (`aws configure sso` in older aws-cli, some OAuth2 PKCE flows):

```bash
# Terminal 1: forward the loopback port from the pod to the admin's laptop
kubectl port-forward -n omp-session-NAME pod/omp 8400:8400

# Terminal 2: exec into the pod and run the auth flow; it opens browser on laptop
kubectl exec -it -n omp-session-NAME omp -- bash -lc \
  'aws configure sso --redirect-url http://localhost:8400/callback'
```

**Constraint:** the pod's NetworkPolicy blocks inbound connections, but `kubectl port-forward` rides the K8s API (not pod networking) and is unaffected by NetworkPolicy. The forward is admin-laptop → K8s API → pod, which is allowed.

**Tradeoffs:**
- Works for any browser-redirect flow.
- Requires two terminal panes and coordination.
- Forward is tear-down-safe — close it after auth; no persistent port exposure.
- Not scriptable as a one-liner.

---

## Option C — omp auth-broker as a per-session sidecar (automatic refresh)

`omp auth-broker serve` is a local HTTP server that holds OAuth credentials and handles automatic token refresh. Setting `OMP_AUTH_BROKER_URL` + `OMP_AUTH_BROKER_TOKEN` in the pod env causes omp to use the broker instead of local SQLite.

Deploy the broker as a **sidecar container** in the session pod:

```
Pod omp
├── container: omp          (the agent — existing)
└── container: auth-broker  (omp auth-broker serve --bind localhost:9999)
    volumes: omp-home (shared with omp container; broker SQLite on PVC)
```

The broker and the agent share `$HOME` via the PVC mount. The broker persists its credential database at `~/.omp/agent/agent.db` (same as what `omp auth-broker login` writes to).

**Workflow:**
1. Session created → both containers start.
2. Operator does initial auth once: `kubectl exec -it -n omp-session-NAME -c auth-broker omp-auth-broker -- omp auth-broker login anthropic` (or whichever providers).
3. After that: broker auto-refreshes tokens; agent container uses broker URL. **No further manual re-auth needed** until the refresh token itself expires (Anthropic: ~30 days; GCP: never for user accounts; AWS SSO: policy-dependent).
4. Pod restart: broker restarts, reloads credentials from PVC, resumes auto-refresh. Agent reconnects to local broker. Zero credential loss.

**Implementation:**
- Add a second container spec to `_pod()` in `session_operator.py`:
  ```python
  k8s.V1Container(
      name="auth-broker",
      image=image,   # same omp-session image; omp binary included
      command=["omp", "auth-broker", "serve", "--bind", "localhost:9999"],
      env=[k8s.V1EnvVar(name="OMP_AUTH_BROKER_TOKEN", value=broker_token)],
      volume_mounts=[k8s.V1VolumeMount(name="omp-home", mount_path="/home/omp")],
      security_context=...,   # same as main container
  )
  ```
- Inject into the main container:
  ```python
  OMP_AUTH_BROKER_URL=http://localhost:9999
  OMP_AUTH_BROKER_TOKEN=<same token>
  ```
- `broker_token` can be generated at session creation and stored in a per-session K8s Secret (not in GSM — it's ephemeral, scoped to the pod lifetime).

**Tradeoffs:**
- Automatic token refresh — the big win over Option A.
- Initial auth still requires `kubectl exec -it` once per provider per session.
- Resource cost: +1 container per pod (~50 MB image, minimal CPU).
- Broker runs on `localhost` — not reachable from other pods (NetworkPolicy unchanged).
- Requires generating and injecting the broker token at session-creation time; small operator change.

---

## Option D — shared auth-broker Deployment (cross-session)

A single `omp auth-broker serve` Deployment in `omp-system`; all sessions point to it via `OMP_AUTH_BROKER_URL` in `omp-bootstrap-env`.

**Rejected**: violates per-session credential isolation. A broker in `omp-system` that holds all operators' credentials means a compromised session pod could reach the broker URL and impersonate any other operator's identity. The existing NetworkPolicy blocks pod-to-pod RFC1918 traffic but not traffic to `omp-system` via `127.0.0.1` (localhost of the broker, reachable only if in the same pod). Actually the policy DOES block pod-to-pod between namespaces... but the broker in `omp-system` is accessible at its ClusterIP, which IS RFC1918. So it would be blocked. That said, admin-mediated `kubectl port-forward` access to the broker from any session pod is not something we want to enable.

More importantly: sharing one broker means all operators' personal OAuth tokens live in one database. A credential leak in the broker affects everyone. Keep isolation.

---

## Recommendation

**Short term (low effort): Option A — exec-based auth, documented as the canonical workflow.**

Add these commands to the manager skill and role doc. The operator does one `kubectl exec -it` per provider after session creation. Credentials persist on PVC; manual re-auth required when tokens expire.

**Medium term (worthwhile): Option C — auth-broker sidecar per session.**

Eliminates the re-auth burden for Anthropic, GCP, and Azure (which have long-lived refresh tokens). AWS SSO and GitHub PAT don't benefit as much (shorter token lifetimes or token-based). Sidecar is contained to the session namespace — isolation preserved.

Both options are complements, not alternatives. Option A is the bootstrap path for initial auth; Option C keeps tokens live thereafter.

---

## What to build

### Phase 1: exec-based auth tooling (manager skill + image)

1. **Verify CLIs are in the session image**: `gcloud`, `aws` (v2), `gh`, `az`, `omp` are all present or addable to `Dockerfile`. Currently: `gh` ✓, `omp` ✓. Need to add: `gcloud` (official apt repo), `aws` (official install script), `az` (official apt repo).

2. **Document exec-based auth flows** in `docs/roles/manager.md` and `.omp/skills/manager/SKILL.md`: one block per provider with the exact `kubectl exec -it` command.

3. **`administrator.sh auth NAME PROVIDER`** subcommand: a thin wrapper that runs `kubectl exec -it` into the right pod for the right provider — avoids the operator having to remember the namespace format. Example:
   ```bash
   ./administrator.sh auth work anthropic   # execs omp auth-broker login anthropic
   ./administrator.sh auth work gcloud      # execs gcloud auth login --no-browser
   ./administrator.sh auth work aws         # execs aws sso login --no-browser (with profile prompt)
   ./administrator.sh auth work az          # execs az login --use-device-code
   ./administrator.sh auth work gh TOKEN    # pipes token to gh auth login --with-token
   ```

4. **Port-forward wrapper** `administrator.sh port-forward NAME PORT` for browser-redirect flows that need local browser.

### Phase 2: auth-broker sidecar (operator change)

1. **CRD**: add optional `spec.authBroker: bool` (default `false`). When `true`, operator adds the sidecar container and injects `OMP_AUTH_BROKER_URL` + `OMP_AUTH_BROKER_TOKEN` into the main container env.

2. **Operator**: generate a random 32-byte broker token at session creation; store it in a per-session K8s Secret `auth-broker-token` in the session namespace; inject as env in both containers.

3. **Sidecar exec** for initial auth: `kubectl exec -it -n omp-session-NAME -c auth-broker omp -- omp auth-broker login PROVIDER`.

4. **Verify**: broker auto-refreshes Anthropic token; agent uses broker; token survives pod restart without re-auth.

---

## Provider-specific notes

### Anthropic
- `omp auth-broker login anthropic` → device code (prints URL + code). Refresh token is long-lived (~30 days). With sidecar, this is a one-time-per-session auth.
- Current workaround: `anthropic-oauth` K8s Secret in `omp-system` (holds access + refresh token). This works but requires the admin to update it when the refresh token expires. The sidecar approach is cleaner.

### GCP / gcloud
- `gcloud auth login --no-browser` → device code. ADC token expires ~1 h; refresh token never expires for Google accounts.
- Service account key files are the alternative (already documented in credential-management.md).
- With sidecar: gcloud stores tokens in `~/.config/gcloud/` on PVC; gcloud itself handles refresh; no broker needed for gcloud (gcloud is its own auth handler). The sidecar is not involved here — Option A (one exec) is sufficient.

### AWS SSO
- `aws configure sso` opens a browser. Use `aws sso login --profile PROFILE --no-browser` (aws-cli ≥ 2.15) for device code.
- SSO session tokens expire per the SSO portal policy (typically 8–12 h). Refresh requires re-running `aws sso login`.
- SSO tokens stored in `~/.aws/sso/cache/` on PVC.
- No broker benefit (broker handles OAuth2, not AWS SSO's proprietary flow). Option A is the only path.

### GitHub
- PAT: inject via GSM/ESO (already works). No interactive flow needed.
- Fine-grained PAT: same.
- If personal GitHub identity is needed: `gh auth login --with-token` (pipe PAT on stdin — non-interactive, no browser).

### Azure
- Service principal: inject via GSM/ESO (already works).
- Personal identity: `az login --use-device-code` → device code. Token expires ~1 h; refresh is automatic by `az` itself (stored in `~/.azure/`). One exec, then az manages its own refresh. No sidecar needed.

---

## Security properties preserved

| Property | Option A | Option C |
|---|---|---|
| Per-session namespace isolation | ✓ (credentials on session's own PVC) | ✓ (broker is localhost-only; PVC-scoped) |
| No cross-session credential access | ✓ | ✓ (each session has its own broker + PVC) |
| NetworkPolicy unchanged | ✓ | ✓ (broker on localhost; no new ports opened) |
| No GCE metadata server access | ✓ | ✓ |
| Credentials never echoed | ✓ (device code flows never print the token) | ✓ |
| PVC = single source of truth | ✓ | ✓ (broker DB is on PVC) |
