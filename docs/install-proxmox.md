# Install on Proxmox VE

One command on a Proxmox VE host gives you a Debian LXC with Docker and one or
more **GitHub Actions self-hosted runners**. Each runner is a Docker container
whose image is modeled on GitHub's hosted `ubuntu-24.04` runner. The image is
downloaded prebuilt, and the caches stay inside the LXC (see [Caching](caching.md)),
so CI is fast even on small hosts.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Quavon-dev/Quavon-Runners/main/install.sh)"
```

No Proxmox? The same runners install on any Debian/Ubuntu VM or server with `_ host`:
see [Install on Debian or Ubuntu](install-linux.md).

## A fixed version

Every [release](https://github.com/Quavon-dev/Quavon-Runners/releases) has its own
`install.sh` that installs exactly that version instead of `main`. The release also holds
`SHA256SUMS` and a signed build provenance:

```bash
curl -fsSLO https://github.com/Quavon-dev/Quavon-Runners/releases/download/v0.1.0/install.sh
gh attestation verify install.sh --repo Quavon-dev/Quavon-Runners
bash install.sh
```

## The wizard

The wizard asks for:

1. **The pair code.** In GitHub, open **Settings → Actions → Runners → New self-hosted runner**
   (repo, organisation or enterprise) and paste the whole
   `./config.sh --url https://github.com/... --token XXXXX` line. URL and token are
   read from it. The token is valid for **1 hour**, and runners are registered
   before the image build so a slow build can't outlast the token.
2. **Runner mode.** See [Persistent vs. ephemeral](#persistent-vs-ephemeral).
3. **Image flavor** (`standard`, `full` or `full-plus`; see [Runner images](images.md)).
4. **Parallel jobs.** How many runners you want, and whether they share one LXC
   or each get their own (see [Parallel jobs](#parallel-jobs)).
5. **Size per runner** (`small` / `medium` / `large` / `xlarge` / `custom`;
   see [Sizing](#sizing)).
6. **Network access.** `internet` (default) blocks the LAN, or `lan` leaves it open
   (see [Network isolation](#network-isolation)).
7. **Container settings.** `default` uses the computed sizing and DHCP on `vmbr0`. `advanced`
   lets you set the ID, hostname, resources, static IP, VLAN, DNS, LAN exceptions, SSH key
   and privileged mode.
8. **Runner name, labels** and, for orgs or enterprises, a **runner group**.

Then use it in a workflow:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, docker]
```

Invalid input never aborts the wizard: the prompt explains what's wrong and asks
again. Labels are cleaned up automatically, so `docker, linux` becomes `docker`
(`linux` is a built-in label).

Like the Proxmox helper scripts, the installer takes the next free container ID
from Proxmox and doesn't look at your other guests. If the runner name is already
taken in GitHub, it asks you for another name and retries. An existing runner is
never replaced silently.

Every step shows a spinner with what's running and how long it has taken, then a
✔. Long steps (OS update, Docker, image build) show their current sub-step. All
command output goes to `/tmp/gha-runners-install-<date>.log`. If a step fails,
you get a ✖ plus that step's output. `VERBOSE=1` shows all output live, and
`DEBUG=1` adds a shell trace in `/tmp/gha-install.log`.

If the SSH or web-console session drops, the installer keeps running in the
background and writes everything to the log: `tail -f /tmp/gha-runners-install-*.log`.

## What you get

| | |
|---|---|
| LXC | Debian 13 (falls back to 12), unprivileged, `nesting,keyctl,fuse`, starts on boot, lower CPU priority than your other guests |
| Network | internet only by default: LAN, Proxmox host and IPv6 blocked by the host firewall |
| Runners | official `actions/runner`, auto-updating, one systemd service per runner |
| Docker in jobs | `docker build/run`, `services:`, `container:` jobs, buildx, compose |
| Networking | `--network host`, so `services:` ports work on `localhost` like on hosted runners |
| Hosted-runner parity | user `runner` (uid 1001) with passwordless `sudo`, `/opt/hostedtoolcache`, `ImageOS=ubuntu24`, so `actions/setup-*` work |
| Caching | `actions/cache`, `setup-*` caches and BuildKit `type=gha` served from the LXC, Docker Hub pull-through mirror, npm/pip/Go/pnpm/bun/NuGet caches kept between jobs ([Caching](caching.md)) |
| Image | prebuilt on GHCR and pulled, built locally only for changed scripts ([Runner images](images.md)) |
| Cleanup | containers a job left running (`docker run -d`, `compose up -d`) removed before the next job, any other container (e.g. a `kind` cluster) once it has run for 24 hours ([details](operations.md#leftover-containers)), workspace wiped, file ownership fixed after container jobs, hourly Docker prune, build cache capped at a quarter of the disk |
| Full disk | 10% of the disk is held back from jobs, so a full disk can always be cleaned up (see [Full disk](operations.md#full-disk)) |

## Persistent vs. ephemeral

| | Persistent (default) | Ephemeral |
|---|---|---|
| Needs | pair code only | fine-grained PAT: repo **Administration: write** or org **Self-hosted runners: write** |
| Between jobs | workspace wiped, container keeps running | runner re-registers, and every job gets a brand-new container from the image, like GitHub-hosted |

## Parallel jobs

A runner executes **one job at a time**. *N* runners means *N* jobs at once, and
any further jobs wait in GitHub's queue. You choose where the runners live:

| Layout | What you get | Use when |
|---|---|---|
| `shared` (default) | 1 LXC, *N* runners, one Docker, disk and image | light jobs from trusted repos; least overhead |
| `separate` | *N* LXCs, 1 runner each, each with its own firewall and Docker | Docker builds, `services:` or `container:` jobs, heavy builds, untrusted or mixed repos |

In `shared`, the per-runner cap only covers the runner itself. Containers a job
starts (`docker build`, `services:`, `container:` jobs) share the whole LXC, so one
of them can starve the other runners. In `separate`, the LXC limits cover
everything a job starts, and `nproc` shows the runner's real core count.

`separate` costs about 0.5 GB of RAM plus one image copy (~3, ~13 or ~15 GB of disk)
per extra container. The image is built only once and copied to the others. All
runners are registered before the build, so the 1-hour pair code doesn't expire.
With a static IP, the address is counted up per container (`.50`, `.51`, …).
The LXCs of a `separate` install share one cache directory
([One cache for several LXCs](caching.md#one-cache-for-several-lxcs)).

## Sizing

Choose a **per-runner size**. Each runner container is capped at that size
([Parallel jobs](#parallel-jobs) explains what the cap covers). The LXC totals
are computed from the size and the runner count:

| Preset | CPU / runner | RAM / runner | Job disk / runner | Good for |
|---|---|---|---|---|
| `small` | 1 | 2 GB | 4 GB | lint, unit tests, small builds |
| `medium` (default) | 2 | 4 GB | 6 GB | typical web and app builds |
| `large` | 4 | 8 GB | 10 GB | Docker image builds, big test suites |
| `xlarge` | 8 | 16 GB | 20 GB | heavy compiles (Rust, C++, Android) |
| `custom` | you choose | you choose | you choose | |

LXC totals:
- **CPU:** runners × CPU, capped at the host's cores minus one, so the host always keeps a core.
- **RAM:** runners × RAM, plus 1 GB for the OS.
- **Disk:** 2 GB OS, plus the image (`standard` ~3 GB, `full` ~13 GB, `full-plus` ~15 GB), plus runners × (1 GB + job disk),
  plus the [disk reserve](operations.md#full-disk) (a ninth on top, so jobs still get their full job disk).

For example, 2 × `medium` with `standard` gives 4 cores, 9 GB RAM and 22 GB disk.
In advanced mode you can override every total.

CPU and RAM are **limits, not reservations**: an idle runner uses about 150 MB.
On LVM-thin and ZFS the disk is thin-provisioned, so only data actually written
takes space. Unused job images are pruned once the disk is 80% full (checked hourly
and before every job), and a reserve keeps a full disk from taking the runners down ([Full disk](operations.md#full-disk)).

The runner LXCs get `cpuunits 50` (Proxmox default: 100). When the host is busy,
your other VMs and containers get twice the CPU share of CI jobs. Set
`CPU_UNITS` to change this. If the CPU limits of all runner LXCs add up to more
than the host has, the installer asks before it continues.

**Parallel workers.** In `shared`, `nproc` inside a runner shows every core of the
LXC, not the runner's cap. Tools that start one worker per core then run far more
workers than the cap allows, which throttles the job and can run it out of memory.
Each runner therefore gets `GOMAXPROCS`, `CARGO_BUILD_JOBS`,
`CMAKE_BUILD_PARALLEL_LEVEL` and `PYTEST_XDIST_AUTO_NUM_WORKERS` set to its CPU cap.
Jest and Vitest have no such variable: pass `--maxWorkers=<CPU cap>` in your
workflows.

**Storage.** The installer stops if Docker in the LXC can only use the `vfs` or
`native` storage driver. Those copy the whole runner image for every container.
On ZFS this happens before Proxmox VE 8.1 (ZFS 2.2). Upgrade, or put the container
on LVM-thin or directory storage.

**ZFS sync writes.** On ZFS storage the installer sets `sync=disabled` on the
container's dataset. `dpkg`, `npm`, image extraction and database service containers
force writes to disk all the time, and on ZFS that's often the slowest part of a job.
If the host crashes, the last ~5 seconds of writes are lost. ZFS itself stays
consistent, and CI data can be recreated. Set `ZFS_SYNC=standard` to keep sync writes. For
existing containers, on the host: `zfs list | grep subvol-<CTID>`, then
`zfs set sync=disabled <dataset>`.

Change limits later:

```text
gha-runners limits                          # show (inside the LXC)
gha-runners limits --cpus 4 --memory 8192   # per-runner caps, restarts runners (0 = unlimited)
pct set <CTID> --cores 8 --memory 16384     # LXC totals (on the Proxmox host)
pct set <CTID> --cpuunits 50                # CPU priority, e.g. for runners installed before it was set
pct resize <CTID> rootfs +10G               # grow the disk (on the Proxmox host)
```

## Network isolation

By default the container can reach **the internet only**. It cannot reach your LAN,
the Proxmox host, your router, other VMs and containers, or anything over IPv6, and
nothing can connect into it. Jobs still have full access to GitHub, package
registries and Docker Hub.

The rules are enforced by the **Proxmox firewall on the host**, on the container's
network interface. Rules inside the container would be useless because jobs
effectively have root there.

| Rule | Effect |
|---|---|
| inbound policy `DROP` | no connections into the container (`pct enter` still works) |
| `REJECT` to 10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16, multicast | LAN, CGNAT and link-local blocked |
| `REJECT` to the Proxmox host's own IPs | host blocked even if it has public addresses |
| `REJECT` all IPv6 | LAN devices with global IPv6 addresses can't be reached |
| DNS via [DNS.SB](https://dns.sb/) (`185.222.222.222` / `45.11.45.11`), kept even when DHCP hands out a LAN resolver | a LAN resolver isn't needed |
| `ACCEPT` to `LAN_ALLOW` entries | opt-in exceptions, e.g. an internal registry or GitHub Enterprise Server |

If DHCP hands a container the Proxmox host's own address (the host has a static IP
inside the router's DHCP range), the installer stops that container at once and tells
you to reserve the address in the router or use static IPs. Otherwise both answer on
the same IP and SSH to the host drops.

The installer checks that this works: `github.com` must be reachable, and the
Proxmox web UI (`:8006`) and the gateway must not be. If either check fails, it aborts.

**Datacenter firewall:** guest firewalls only apply when the datacenter firewall
is on. If it's off, the installer asks before turning it on with input policy
`ACCEPT`, so the host and other guests behave exactly as before. If the
datacenter firewall is off but already has a `DROP` input policy configured, the
installer warns you first, because turning it on could lock you out of the web UI or SSH.

Rules live in `/etc/pve/firewall/<CTID>.fw` on the host. You can also view them in
the UI under **CT → Firewall**. For even stronger separation, put the container on
its own VLAN (advanced settings).

## Non-interactive install

Every prompt has an environment variable:

```bash
NONINTERACTIVE=1 \
GH_URL=https://github.com/my-org GH_TOKEN=AAAA... \
RUNNER_COUNT=4 SIZE=large RUNNER_FLAVOR=full RUNNER_LABELS=docker,big \
CTID=150 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Quavon-dev/Quavon-Runners/main/install.sh)"
```

Other variables: `LAYOUT=shared|separate`, `SIZE=custom` with `RUNNER_CPUS` / `RUNNER_MEM`, `CORES` / `RAM` / `DISK`
(override the totals), `NET_ISOLATION=internet|lan`, `DNS_SERVERS`, `LAN_ALLOW=10.0.0.5,10.0.10.0/24`,
`RUNNER_MODE=ephemeral` with `GH_PAT`, `RUNNER_PREFIX`, `RUNNER_GROUP`,
`SHARED_CACHE_GB` / `SHARED_CACHE_HOST` (shared cache of the `separate` layout), `CT_HOSTNAME`, `SWAP`, `CPU_UNITS` (CPU priority, 1-10000, default 50), `ZFS_SYNC=disabled|standard`, `BRIDGE`, `NET_IP` / `NET_GW`, `VLAN`, `SSH_KEYS`, `UNPRIVILEGED`,
`REPO_URL` / `REPO_BRANCH` (forks, see [Forking](forking.md)).

For a private fork, clone it on the Proxmox host and run `./install.sh`. The local
checkout is copied into the container and nothing is cloned.
