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

## 2. Authenticate the model (first time per session)

If `omp-bootstrap-env` is present in `omp-system` (see the [administrator guide](administrator.md)),
the operator copies it into the session namespace automatically. The session starts
immediately and the join link appears in `.status.joinLink` — no manual auth step is
required before joining. Once inside the session, complete Anthropic OAuth via the omp
TUI or by typing `/auth login` in the agent pane.

**Fallback — manual auth (no bootstrap env):**

```bash
kubectl exec -it -n omp-session-work omp -- bash
# Inside the container:
omp auth login
```

> **Note:** `bash -lc 'omp auth login'` may not work if `omp` is not on `PATH` in the
> pod's login shell — drop into an interactive `bash` session and run `omp auth login`
> directly.

The resulting token is written to `~/` on the pod's PVC (`omp-home`) and persists
across pod restarts. You only need to do this once per session lifecycle.

> **Tip:** If the administrator stored the Anthropic API key with
> `./administrator.sh vault-add model/anthropic/api-key` and the session was
> launched with `subtrees: ["services", "model"]`, the session injects
> `ANTHROPIC_API_KEY` and no interactive login is needed.

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

To swap in new per-session skills: delete and re-create the session — assets are seeded
fresh from the image each boot. Skills are discovered at session startup, not
hot-reloaded; a restart is the reload.

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
- **Config change not picked up.** Delete the pod to force a restart:
  `kubectl delete pod omp -n omp-session-NAME`.

## What you don't do

You never provision, start/stop, or destroy the GKE cluster — that's the
[administrator](administrator.md). You never build or push images — that's the GHCR CI
workflow. You never run `./administrator.sh` for session operations — those are plain
`kubectl`. Operators just join the link you give them.
