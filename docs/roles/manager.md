# Manager Guide

You are the **manager**. You create and share the sessions people work in. You assume
the [administrator](administrator.md) has already provisioned the GKE cluster, run
`bootstrap` and `setup`, and stored the necessary credentials with `vault-add`.

You manage sessions directly with **`kubectl`** — there is no manager script. All
platform config and vault operations use `./administrator.sh`.

## Before you start

- `kubectl` installed; cluster credentials fetched:
  ```bash
  gcloud container clusters get-credentials omp-cluster --zone=europe-west1-b
  ```
  Or: `./administrator.sh credentials`.
- The cluster is up: `./administrator.sh status` shows `RUNNING` nodes and the operator
  Deployment is Available.
- No GPG key, no vault passphrase, no vault init.

## 1. Launch a session

```bash
kubectl apply -f - <<EOF
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: work
  namespace: omp-system
spec:
  subtrees: ["services"]
  view: false
EOF
```

This applies a `Session` CR to the namespace specified in the manifest. The operator
provisions an isolated namespace (`omp-session-work`), syncs the `services` subtree from
GSM into a per-namespace Secret, and launches an `omp` pod.

> **Namespace choice:** The Session CR can live in any namespace — `omp-system` and
> `omp-sessions` are both conventional choices. Pick one and use it consistently across
> all commands below.

Want a different subtree — or multiple subtrees? Adjust `spec.subtrees`:

```yaml
spec:
  subtrees: ["services", "model"]
```

Wait for the session to be ready:

```bash
kubectl wait --for=jsonpath='{.status.phase}'=Hosting \
  session/work -n <namespace> --timeout=180s
```

No passphrase is prompted. Credentials are injected from the session's own namespace
Secret.

## 2. Authenticate providers (first time per session)

Session credentials arrive in two ways:

- **Static keys / API tokens** (Gemini, JIRA, GitHub PAT, AWS long-term keys, etc.):
  stored in GSM via `vault-add`, synced into the session pod at startup via ESO. No
  interactive step needed — the session starts authenticated.

- **Interactive OAuth / SSO flows** (Anthropic, gcloud personal ADC, AWS SSO, Azure
  personal account): require a one-time device-code or browser-based login _inside_
  the pod. Use `./administrator.sh auth`:

```bash
# Anthropic — device code (visit the printed URL in your browser)
./administrator.sh auth work anthropic

# GCP personal ADC — device code
./administrator.sh auth work gcloud

# AWS SSO — device code (requires an SSO profile; configure first if needed)
./administrator.sh auth work aws-configure   # one-time SSO profile wizard
./administrator.sh auth work aws             # subsequent logins

# Azure personal account — device code
./administrator.sh auth work az

# GitHub — paste a PAT on stdin (non-interactive)
printf '%s' "$MY_GITHUB_PAT" | ./administrator.sh auth work gh
```

All credentials land under `$HOME` on the PVC and survive pod restarts. You only need
to do this once per session (or when the token expires). Token lifetimes:

| Provider | On-disk location | Re-auth needed |
|---|---|---|
| Anthropic (`omp`) | `~/.omp/agent/agent.db` | ~30 days (refresh token) |
| GCP (`gcloud`) | `~/.config/gcloud/` | never (refresh token doesn't expire) |
| AWS SSO | `~/.aws/sso/cache/` | per SSO portal policy (~8–12 h) |
| Azure | `~/.azure/` | ~90 days (refresh token) |
| GitHub (`gh`) | `~/.config/gh/hosts.yml` | never (PAT-based) |

**Browser-redirect flows** (some `aws configure sso` paths): use the port-forward
helper so the redirect lands on your laptop's browser:

```bash
# Terminal 1 — forward pod port to localhost
./administrator.sh port-forward work 8400
# Terminal 2 — run the wizard pointing at the forwarded port
kubectl exec -it -n omp-session-work omp -- bash -lc \
  'aws configure sso --redirect-url http://localhost:8400/callback'
```

### Auth-broker sidecar (automatic token refresh)

For long-running sessions where tokens expire and manual re-auth is disruptive, add
`spec.authBroker: true` to the Session CR. The operator adds an `omp auth-broker serve`
sidecar container to the pod. omp connects to it via `OMP_AUTH_BROKER_URL=http://localhost:9999`;
the broker handles refresh automatically once initial auth is done.

```bash
kubectl apply -f - <<EOF
apiVersion: omp.mirantis.io/v1alpha1
kind: Session
metadata:
  name: work
  namespace: omp-system
spec:
  subtrees: ["services"]
  authBroker: true
EOF

# Initial auth (exec into the auth-broker container, not the omp container)
./administrator.sh auth work anthropic auth-broker
./administrator.sh auth work gcloud    auth-broker
```

After initial auth, the broker auto-refreshes tokens. Credentials survive pod restarts
because the broker's SQLite database is on the shared PVC. No re-auth needed until the
refresh token itself expires (~30 days for Anthropic, never for GCP personal accounts).

## 3. Share it

```bash
kubectl get session work -n <namespace> -o jsonpath='{.status.joinLink}'
```

This prints the join link. Hand `omp join "<link>"` to your operators
(see the [operator guide](operator.md)). For a read-only link:

```bash
kubectl get session work -n <namespace> -o jsonpath='{.status.viewLink}'
```

If the link is empty (e.g. a pod just restarted), trigger a re-capture and wait ~30 s:

```bash
kubectl annotate session work -n <namespace> \
  omp.mirantis.io/recapture=$(date +%s) --overwrite
```

## 4. Drive, list, end

```bash
# Attach to the session tmux (take the keyboard yourself)
kubectl exec -it -n omp-session-work omp -- tmux attach -t omp

# List all sessions
kubectl get sessions -A

# Delete the session (operator GCs namespace + PVC)
kubectl delete session work -n <namespace>
```

> **`kubectl delete session` is the only operation that destroys the PVC.** Stop,
> restart, and image-move all preserve it.

### Stop / start / restart / image-move (preserve PVC + conversation)

The omp conversation is stored on the PVC under `~/.omp/agent/sessions/` and is
resumed automatically via `omp -c` on every pod start. These operations never
touch the PVC:

```bash
# Stop: removes the pod; namespace, PVC, secrets, NetworkPolicies stay
kubectl patch session work -n <namespace> \
  --type=merge -p '{"spec":{"state":"stopped"}}'

# Start: recreates the pod; conversation resumes from PVC
kubectl patch session work -n <namespace> \
  --type=merge -p '{"spec":{"state":"running"}}'

# Restart: always moves to latest image + preserves conversation
kubectl patch session work -n <namespace> \
  --type=merge -p "{\"spec\":{\"image\":null},\"metadata\":{\"annotations\":{\"omp.mirantis.io/restartedAt\":\"$(date +%s)\"}}}"

# Move to a specific pinned image
kubectl patch session work -n <namespace> \
  --type=merge -p '{"spec":{"image":"ghcr.io/james-nesbitt/collab-agent/omp-session:sha-XXXX"}}'
```

After any restart/start/image-move the collab link rotates. The operator
re-captures it automatically; if `status.joinLink` is empty, trigger re-capture:

```bash
kubectl annotate session work -n <namespace> \
  omp.mirantis.io/recapture=$(date +%s) --overwrite
```

Note: restarting a `stopped` session via the restart annotation is deferred — the
operator's stopped branch takes priority. Set `state: running` first.

To swap skills: restart the pod (annotation bump) — assets are re-seeded from the
image on each pod start. Skills are discovered at session startup.

## Credential isolation

Per-session isolation is realized:

- **Namespace isolation:** each session runs in its own `omp-session-NAME` namespace;
  its pod can only see Secrets in that namespace.
- **Per-namespace Secret:** the operator syncs only the requested subtrees from GSM
  into the session's own `omp-creds` Secret — other sessions' namespaces are invisible.
- **NetworkPolicy:** deny-all ingress; egress limited to DNS + TCP 443 to the internet,
  with RFC1918 ranges and `169.254.169.254` (GCE metadata server) blocked.

A joined guest is still inside the credential trust boundary of their session
(obfuscation hides values from the model; the guest sees real values on tool cards).
But guests are confined to that session's credentials.

## Troubleshooting

- **Session stuck waiting for `Hosting`.** Check the operator logs:
  `kubectl logs -n omp-system deploy/omp-operator`. Common causes: the `omp-creds`
  ExternalSecret is not Valid (only applicable when `spec.subtrees` is non-empty; with
  empty subtrees the ExternalSecret is skipped entirely — GSM labels mismatch or ESO
  ClusterSecretStore not ready → re-run `./administrator.sh setup`), or the pod failed
  to start (image pull error — `kubectl describe pod omp -n omp-session-NAME`).
- **Collab link is empty.** The pod may have just restarted; trigger re-capture (above)
  and wait ~30 s. If still empty, exec into the session and check the omp pane directly.
- **A var is missing / subtree exported nothing.** Check GSM labels:
  `./administrator.sh vault-ls services`. An empty subtree → session launches without
  those creds.
- **A value isn't obfuscated.** The env-var name lacks a secret keyword — add a regex
  to `platform/secrets.yml` and re-run `./administrator.sh setup`.
- **Config change not picked up.** Use the restart annotation instead of deleting the
  pod directly:
  `kubectl annotate session NAME -n omp-system omp.mirantis.io/restartedAt=$(date +%s) --overwrite`

## What you don't do

You never provision, start/stop, or destroy the GKE cluster — that's the
[administrator](administrator.md). You never build or push images — that's the GHCR CI
workflow. You never run `./administrator.sh` for session operations — those are plain
`kubectl`. Operators just join the link you give them.
