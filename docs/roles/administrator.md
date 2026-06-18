# Administrator Guide

You are the **administrator**. Your job is to stand up and maintain the GCP VM that
everything else runs on — nothing more. Once the box exists and has the `omp` runtime
installed, you hand off to the [manager](manager.md), who owns omp itself.

Everything you do goes through **`administrator.sh`**, run from this repo on your
laptop. All access tunnels over `gcloud ssh` + IAP, so you never open inbound ports.

## Before you start

- `gcloud` installed and logged in (`gcloud auth login`).
- IAM on the project: OS Login and `roles/iap.tunnelResourceAccessor` (so IAP SSH
  works).
- The defaults target project `tools-348616`, instance `omp-agent`, zone
  `europe-west1-b`. To point elsewhere, export `INSTANCE_NAME`, `ZONE`, `REGION`, etc.
  before running (see the end of this guide).

## 1. First time: create the VM

```bash
./administrator.sh provision
```

This reserves a static external IP and creates the instance. It is idempotent — if the
IP or VM already exist it skips them. When it finishes you'll see the instance name,
zone, and static IP, plus the next steps.

## 2. First time: install the runtime

```bash
./administrator.sh bootstrap
```

This installs system tmux and the rootless-container deps, then mise/bun/omp into your
OS-Login user's home. Run it **once per OS-Login user**; it's idempotent, so re-running
is safe. At the end it prints the installed tool versions — confirm `omp --version`
shows up.

Now hand off: the manager runs `./manager.sh setup` (see the [manager guide](manager.md)).

## 3. Day to day

- **Save money when idle.** The disk persists across stops, so stop the VM overnight or
  on weekends and start it again when needed:
  ```bash
  ./administrator.sh stop
  ./administrator.sh start
  ```
- **Check on it.** `./administrator.sh status` shows the run state and IP;
  `./administrator.sh ip` prints just the static IP.
- **Get a shell.** `./administrator.sh ssh` drops you onto the VM; append
  `-- <args>` to pass extra flags to `gcloud compute ssh`.

## 4. Tearing it down

```bash
./administrator.sh destroy
```

This permanently deletes the instance and releases the static IP (and cleans the legacy
firewall rule if present). It asks you to type `yes` first. **The disk goes with it** —
back up anything you need first.

## Pointing at a different VM

Every default is overridable by environment variable for a single command:

```bash
INSTANCE_NAME=omp-staging ZONE=us-central1-a ./administrator.sh provision
```

| Variable | Default | When it matters |
| --- | --- | --- |
| `INSTANCE_NAME` | `omp-agent` | always |
| `ZONE` / `REGION` | `europe-west1-b` / `europe-west1` | always |
| `MACHINE_TYPE`, `DISK_SIZE`, `DISK_TYPE` | `e2-standard-4`, `200GB`, `pd-balanced` | `provision` only |
| `STATIC_IP_NAME` | `omp-server-ip` | always |
| `USE_IAP` | `true` | set `false` only if you have a public-SSH setup |

## What you don't do

You never configure omp, touch credentials, or create sessions. The moment the runtime
is installed, that's the [manager's](manager.md) job. If something's wrong with a
*session* (not the VM), it's a manager problem. For the bigger picture — why there are
no inbound ports, how collab and credentials work — read
[the architecture doc](../architecture.md).
