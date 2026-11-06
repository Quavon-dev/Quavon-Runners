# Quick start without Proxmox

The runners don't need Proxmox. On a plain Debian or Ubuntu machine (a VM, a cloud
server or bare metal) the installer sets up Docker, the `gha-runners` CLI, the
systemd units and the caches straight on that machine. That's the same setup it
puts inside a runner LXC on Proxmox.

> **Use a dedicated VM.** Jobs can reach the machine's Docker socket, so they get
> **root on the whole machine**. Proxmox normally keeps runner jobs off your LAN
> with a firewall, but a plain machine has no such firewall: jobs can reach
> everything the machine can. Never install the runners on your workstation or on a
> server that does other work. Don't attach them to public repositories that run
> workflows from fork pull requests.

## Requirements

- Debian 12 or 13, or Ubuntu 22.04 or 24.04, with systemd, run as root.
- `amd64` downloads the prebuilt runner image. `arm64` works too, but the image is
  built on the machine (`standard` takes a few minutes, `full` takes much longer).
- No Docker yet, or Docker CE from `download.docker.com`. Docker from `docker.io`, snap
  or rootless Docker is refused.
- Per runner: the CPU and RAM of its size (`small` 1 CPU / 2 GB, `medium` 2 / 4 GB,
  `large` 4 / 8 GB, `xlarge` 8 / 16 GB), plus 1 GB RAM for the OS.
- Disk: 2 GB, plus the image (`standard` ~3 GB, `full` ~13 GB, `full-plus` ~15 GB),
  plus about 7 GB per `medium` runner. The installer warns when `/` has less free space.
- Outbound HTTPS to GitHub, `ghcr.io`, `download.docker.com` and Docker Hub.

## Install

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/quavon-dev/quavon-docker-runners/main/install.sh)" _ host
```

The wizard asks for the same things as on Proxmox: the pair code (the
`./config.sh --url ... --token ...` line from **Settings → Actions → Runners → New
self-hosted runner**), the runner mode, the image flavor, the number of parallel
jobs, the size per runner, the runner name, the labels and, for organisations, the
runner group. The installer clones the repository to `/opt/quavon-docker-runners`,
then runs `lxc/setup.sh docker`, `register` and `start` on the machine.

The token is never put on a command line or written to the log. It goes to
`config.sh` through a root-only file that is deleted right after it's read.

On a Proxmox VE host, `_ host` refuses to run. Use the normal installer there.

### Non-interactive

```bash
sudo NONINTERACTIVE=1 \
  GH_URL=https://github.com/my-org GH_TOKEN=AAAA... \
  RUNNER_COUNT=2 SIZE=medium RUNNER_FLAVOR=standard RUNNER_LABELS=docker \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/quavon-dev/quavon-docker-runners/main/install.sh)" _ host
```

| Variable | Default | |
|---|---|---|
| `GH_URL`, `GH_TOKEN` | | repo, org or enterprise URL and its registration token |
| `RUNNER_MODE=ephemeral`, `GH_PAT` | `persistent` | ephemeral runners need a PAT ([README](../README.md#persistent-vs-ephemeral)) |
| `RUNNER_COUNT` | `2` | jobs at the same time (1-32) |
| `SIZE` | `medium` | `small`, `medium`, `large`, `xlarge`, or `custom` with `RUNNER_CPUS` / `RUNNER_MEM` (MB) |
| `RUNNER_FLAVOR` | `standard` | `standard`, `full`, `full-plus` |
| `RUNNER_PREFIX` | host name | runner name; `-1`, `-2`, ... is appended when there are several |
| `RUNNER_LABELS` | `docker` | extra labels |
| `RUNNER_GROUP` | | org or enterprise runner group |
| `SHARED_DOCKER=1` | | see [Docker with other workloads](#docker-with-other-workloads) |
| `REPO_URL`, `REPO_BRANCH` | | install from a fork |

Pass secrets through the environment, as above. In the interactive wizard, nothing
needs to be passed on the command line. Remember that `export GH_TOKEN=...` in a shell
ends up in its history: type ` GH_TOKEN=...` with a leading space, or use the wizard.

## Security

- **Jobs have root on the machine.** They can use the Docker socket to start
  privileged containers and mount the host's file system. Treat the machine as part
  of your CI, not as a server you trust.
- **No network isolation.** Jobs can reach your LAN, cloud metadata endpoints and
  everything else the machine can. Put the VM in its own network or VLAN, or block
  private ranges with a firewall in front of it or on the hypervisor (security
  groups, the Proxmox/Hyper-V/VMware firewall, nftables on another host). A firewall
  *inside* the VM doesn't help: jobs are root there and can change it.
- The caches (actions cache, Docker Hub mirror, package and Git caches) are shared
  by every job on the machine, across repositories. Only attach repositories that
  trust each other ([README › Security](../README.md#security)).

## Docker with other workloads

The runners clean up the whole Docker, not only their own data. The hourly prune and
the cleanup at 80% disk remove stopped containers, unused images and unused volumes.
When the disk is full, the disk guard does the same. On a dedicated machine that is
exactly what you want. On a machine where Docker runs other things, it deletes them.

So the installer stops if Docker already has containers or volumes, unless you
confirm (or set `SHARED_DOCKER=1`). With `SHARED_DOCKER=1` in
`/etc/gha-runners/config.env`:

- running containers are never removed (no [leftover container](../README.md#leftover-containers) cleanup),
- `gha-runners update` doesn't switch Docker to the classic image store, because that
  deletes every image and container,
- Docker keeps its image store. The installer only adds the build cache limit and
  the Docker Hub mirror to `/etc/docker/daemon.json`, plus log rotation if that file
  doesn't exist yet.

Stopped containers, unused images and unused volumes are still removed, and the
install restarts Docker. Use a dedicated VM.

## Inside an LXC or VM on another hypervisor

Any VM works: VMware, Hyper-V, VirtualBox, KVM/libvirt, Proxmox VMs, and cloud
servers (EC2, Azure, GCP, Hetzner, DigitalOcean...). Give it the resources from
[Requirements](#requirements) and run the one-liner inside it.

In a **system container** (LXC, LXD, Incus), Docker needs nesting:

| | Setting |
|---|---|
| Incus / LXD | `incus config set <ct> security.nesting=true security.syscalls.intercept.mknod=true security.syscalls.intercept.setxattr=true` (`lxc config set` on LXD) |
| Plain LXC | `lxc.include = /usr/share/lxc/config/nesting.conf`, plus `lxc.apparmor.profile = unconfined` if Docker can't start containers |
| Proxmox LXC | use the normal installer on the host instead: it sets `nesting=1,keyctl=1,fuse=1` |

- **nesting** lets Docker create its own namespaces and mount `/proc` and `/sys`.
- **keyctl** (unprivileged containers) lets Docker and runc use the kernel keyring.
  Without it, starting containers fails with `permission denied` on `keyctl`.
- **fuse** is needed only by jobs that use FUSE (`fuse-overlayfs`, AppImages, sshfs).
- The container's root file system should be on ext4, XFS, ZFS 2.2+ or Btrfs. When
  Docker can only use the `vfs` storage driver, the installer stops, because `vfs`
  copies the whole runner image for every container.
- If the installer reports that Docker can't run a test container, it's almost
  always missing nesting/keyctl or an AppArmor profile that blocks it.

OpenVZ/Virtuozzo containers and WSL are not supported.

## Manage, update, uninstall

```text
gha-runners list | add | remove <name> | logs <name> -f | restart | limits | doctor | prune
gha-runners update      # pull the latest scripts and image, restart the runners
```

Running the install one-liner again on a machine that already has runners also
updates it (`gha-runners update`). Updating restarts the runners, so running jobs
are cancelled.

Uninstall:

```bash
for f in /etc/gha-runners/runners/*.env; do n="$(basename "$f" .env)"; gha-runners remove "$n"; done
systemctl disable --now gha-runners-prune.timer gha-runners-diskguard.service \
  gha-runners-cache@actions.service gha-runners-cache@mirror.service
rm -f /etc/systemd/system/gha-runner@.service /etc/systemd/system/gha-runners-*
systemctl daemon-reload
docker rm -f gha-cache-actions gha-cache-mirror
docker image rm $(docker images -q --filter label=com.quavon.gha-runner)
rm -rf /usr/local/bin/gha-runners /usr/local/lib/gha-runners /etc/gha-runners /srv/gha-runners \
  /var/lib/gha-runners /var/cache/gha-runners /opt/quavon-docker-runners
```

`gha-runners remove` asks for the removal token from GitHub (**Settings → Actions →
Runners → the runner → Remove**). Docker itself stays installed. Remove it with
`apt-get purge docker-ce docker-ce-cli containerd.io` if nothing else needs it.
