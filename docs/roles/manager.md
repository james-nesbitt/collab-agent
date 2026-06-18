# Manager Guide

You are the **manager**. You own omp on the cluster: you configure the platform once,
you hold the credentials in GCP Secret Manager, and you create and share the sessions
people actually work in. You assume the [administrator](administrator.md) has already
provisioned the GKE cluster and run `bootstrap`.

Everything you do goes through **`manager.sh`**, run from this repo on your laptop. It
drives the cluster via `kubectl` (wrapped in `kctl` internally) and `gcloud secrets` —
no SSH, no IAP, no tmux remote-steering.

## Before you start

- `gcloud` installed and logged in (`gcloud auth login`); credentials that the
  administrator granted `roles/container.admin` to your account.
- `kubectl` installed; the administrator's `bootstrap` run fetches cluster credentials
  automatically, so you can also grab them yourself:
  ```bash
  gcloud container clusters get-credentials omp-cluster --zone=europe-west1-b
  ```
- The cluster is up: `./administrator.sh status` shows `RUNNING` nodes and the operator
  Deployment is Available.
- That's it — no GPG key, no vault passphrase, no vault init.

## 1. First time: configure the platform

```bash
./manager.sh setup
```

One idempotent command does several things:

1. Applies the ESO `ClusterSecretStore omp-gsm` (backed by GCP Secret Manager via
   Workload Identity) — this is the bridge between GSM and per-session Kubernetes
   Secrets.
2. Creates (or patches) the master `omp-config` ConfigMap in `omp-system` with:
   - Global secret obfuscation (`secrets.enabled: true`) so credential values are
     replaced with `#XXXX#` before any text reaches the model.
   - `modelRoles`: default `claude-sonnet-4-6`, plan `claude-opus-4-8`, slow + smol
     `claude-haiku-4-5`.
   - Portable agent tuning (editor/task defaults).

You'll see `SETUP_OK`. Re-run any time you change `platform/` files or rotate config
— it overwrites the ConfigMap; running pods pick up the new config on next restart.

No `--passphrase` option exists — at-rest encryption is handled by GCP Secret Manager
IAM, not a GPG key.

### Optional: tune the agent's local models

Two extra capabilities are off by default:

```bash
./manager.sh tune --memory      # mnemopi long-term memory across sessions
./manager.sh tune --thinking    # automatic per-turn thinking-level selection
./manager.sh tune               # both
```

`tune` patches the master `omp-config` ConfigMap. Running pods pick it up on next
restart (`kubectl delete pod omp -n omp-session-NAME` to force it immediately).
Both capabilities run on local ONNX models (`qwen3-1.7b`), CPU-only. Expect `TUNE_OK`.

## 2. Store the credentials people will need

Credentials live in **GCP Secret Manager** under a subtree (default `services`). Add
one by piping the value in on **stdin** — never as an argument, so it never lands in
your shell history or the process list:

```bash
printf '%s' "$MY_GITHUB_TOKEN" | ./manager.sh vault-add services/github/token
```

`vault-add` is idempotent: it creates the GSM secret if absent, then adds a new secret
version. The path is stored with labels `omp_vault=true` and
`omp_subtree=<subtree-slug>` so the operator can enumerate it. Check what's there
(names only, never values):

```bash
./manager.sh vault-ls           # all vault entries
./manager.sh vault-ls services  # one subtree
```

**Naming matters.** The entry path becomes an environment variable name inside the
session: `/` and `-` become `_`, uppercased, with the subtree prefix stripped. So
`services/github/token` → `GITHUB_TOKEN`, which matches omp's `TOKEN` pattern and is
auto-obfuscated. End an entry with a secret keyword (`token`, `key`, `secret`,
`password`) so obfuscation fires. If you must use a name that doesn't match, add a
value-shape regex to `platform/secrets.yml` and re-run `setup`.

**The `mirantis-services` skill needs two entries:**

```bash
printf '%s' "$ATLASSIAN_EMAIL" | ./manager.sh vault-add services/atlassian/email
printf '%s' "$ATLASSIAN_TOKEN" | ./manager.sh vault-add services/atlassian/token
```

They inject as `ATLASSIAN_EMAIL` / `ATLASSIAN_TOKEN`. `token` auto-obfuscates; `email`
is not a secret.

## 3. Launch a session

```bash
./manager.sh new work
```

This applies a `Session` CR to `omp-system`. The operator provisions an isolated
namespace (`omp-session-work`), syncs the `services` subtree from GSM into a
per-namespace Secret, and launches an `omp` pod. The command waits for the session to
reach `Hosting` phase (up to three minutes) and prints attach and collab next-steps.

Want a different subtree — or multiple subtrees?

```bash
./manager.sh new work --subtree clients/acme
./manager.sh new work --subtree services --subtree model
```

No passphrase is prompted. Credentials are injected from the session's own namespace
Secret; the session never touches another session's Secret.

## 4. Authenticate the model (first time per session)

Token-based providers (GitHub, Anthropic API key, etc.) are covered by `vault-add`.
For OAuth-based model auth (Anthropic's interactive login), run:

```bash
./manager.sh login work
```

This drops you into `kubectl exec -it` inside the session pod and runs `omp auth login`
— a device-code or browser flow. The resulting token is written to `~/` on the pod's
PVC (`omp-home`) and persists across pod restarts. You only need to do this once per
session lifecycle (i.e., once per `new`; not after restarts).

> **Tip:** If you store the Anthropic API key with `vault-add model/anthropic/api-key`
> and launch with `--subtree model`, the session injects `ANTHROPIC_API_KEY` and no
> interactive login is needed.

## 5. Share it

```bash
./manager.sh collab work
```

This reads `status.joinLink` from the Session CR and prints the join link:

```
omp join "n8juTBiv...QPNqAGqaEPeSf..."
```

Hand that to your operators (see the [operator guide](operator.md)). For a read-only
link, `./manager.sh collab work view`. If the link is empty (e.g. a pod just restarted
and the operator hasn't re-captured it yet), `collab` triggers a re-capture and waits.

## 6. Drive, list, end

```bash
./manager.sh attach work     # take the keyboard yourself (most recent if NAME omitted)
./manager.sh list            # what's running (all Session CRs in omp-system)
./manager.sh kill work       # delete the Session CR; operator GCs the namespace + PVC
```

To swap in new per-session skills: `kill` then `new` — assets are seeded fresh from
the image each boot, which is rebuilt from `platform/` by the GHCR CI workflow. Skills
are discovered at session startup, not hot-reloaded; a restart is the reload.

## Credential isolation

Per-session isolation is now real. The GKE design gives you:

- **Namespace isolation:** each session runs in its own `omp-session-NAME` namespace;
  its pod can only see Secrets in that namespace.
- **Per-namespace Secret:** the operator syncs only the requested subtrees from GSM
  into the session's own `omp-creds` Secret — other sessions' namespaces are invisible.
- **NetworkPolicy:** deny-all ingress; egress limited to DNS + TCP 443 to the internet,
  with RFC1918 ranges and `169.254.169.254` (GCE metadata server) blocked. A session
  pod cannot reach sibling pods or mint cloud credentials.

A joined guest is still inside the credential trust boundary of their session
(obfuscation hides values from the model; the guest sees real values on tool cards —
that's unchanged). But guests are now confined to that session's credentials. One
session cannot see another session's secrets. This realizes the Tier-2 isolation goal
described in the [credential-isolation planning doc](../planning/credential-isolation.md).

The model still never sees real credential values (`#XXXX#` obfuscation). The installed
`RULES.md` forbids printing secrets. The operational conditions are the same:
tools must not echo credential values to stdout.

## Troubleshooting

- **`new` times out waiting for `Hosting`.** Check the operator logs:
  `kubectl logs -n omp-system deploy/omp-operator`. Common causes: the `omp-creds`
  ExternalSecret is not Valid (GSM labels mismatch or ESO ClusterSecretStore not ready —
  re-run `./manager.sh setup`), or the pod failed to start (image pull, rootless engine
  error — `kubectl describe pod omp -n omp-session-NAME`).
- **`collab` prints an empty link.** The pod may have just restarted; the operator
  recaptures the link on pod restart. Wait ~30 s and retry. If the link is still empty,
  the collab relay handshake in the pod failed — `attach` to the session and check the
  omp pane directly.
- **A var is missing / subtree exported nothing.** Check the GSM labels:
  `./manager.sh vault-ls services`. An empty subtree → the session launches without
  injected creds (operator sets a `message` field; `kubectl get session NAME -n omp-system
  -o jsonpath='{.status.message}'`).
- **A value isn't obfuscated.** The env-var name probably lacks a secret keyword — add a
  regex to `platform/secrets.yml` and re-run `setup` (rebuilds the ConfigMap; pods pick
  it up on restart).
- **`tune` changed config but the pod still has the old values.** Delete the pod to
  force a restart: `kubectl delete pod omp -n omp-session-NAME`. The ConfigMap change
  is not hot-patched into a running container.

## Overriding defaults

Every config var is overridable by environment variable:

| Variable | Default | When it matters |
| --- | --- | --- |
| `GCP_PROJECT` | `tools-348616` | all GSM + cluster ops |
| `CLUSTER_NAME` | `omp-cluster` | all `kctl` calls |
| `ZONE` / `REGION` | `europe-west1-b` / `europe-west1` | cluster credential fetch |
| `OMP_REGISTRY` | `ghcr.io/james-nesbitt/collab-agent` | image refs in Session CRs |
| `OMP_IMAGE_TAG` | `latest` | image tag |

## What you don't do

You never provision, start/stop, or destroy the GKE cluster — that's the
[administrator](administrator.md). You never build or push images — that's the GHCR CI
workflow (`.github/workflows/build-images.yml`), triggered by pushing to the repo.
Operators never run a script; they just join the link you give them.
