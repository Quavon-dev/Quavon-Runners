# Operations

## Managing runners

Open the container with `pct enter <CTID>`, then:

```text
gha-runners list                        # runners and their state
gha-runners add                         # add another runner (asks for a new pair code)
gha-runners add --config "./config.sh --url ... --token ..." --labels gpu
gha-runners remove <name>               # deregister (asks for the removal token) and delete
gha-runners logs <name> -f              # live logs
gha-runners restart [name]              # restart one or all
gha-runners shell <name>                # shell inside a runner container
gha-runners build [--flavor F] [--local] # pull the prebuilt image (--local: build here)
gha-runners limits [--cpus N --memory MB]  # per-runner CPU/RAM caps
gha-runners doctor                      # storage driver, disk, CPU throttling and OOM kills per runner
gha-runners prune [--all]               # Docker cleanup (runs hourly; --all removes every unused image now)
gha-runners migrate-storage             # switch Docker to the classic image store (images stored once)
gha-runners update                      # pull latest scripts and image, restart
```

Limits and sizing are described in [Sizing](install-proxmox.md#sizing), the image flavors
in [Runner images](images.md).

## Updating

Running the install one-liner *inside* an existing runner LXC also does an update.
To update several LXCs from the Proxmox host, one after another without cancelling jobs:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Quavon-dev/Quavon-Runners/main/install.sh)" _ update 124 128 129 130
```

To give existing LXCs one shared cache, use `_ share-cache` the same way
(see [One cache for several LXCs](caching.md#one-cache-for-several-lxcs)).

## Leftover containers

Containers a job starts for its workspace (`docker run -d`, `compose up -d`) are removed
before the runner's next job. Others can't be tied to a job, such as a `kind` cluster or a
`docker run -d` without the workspace, so the hourly prune removes them, with their
anonymous volumes, once they have run for 24 hours. No job runs that long.
Runners, cache servers and containers labelled `com.quavon.keep=true` are never removed.
Change the age with `LEFTOVER_MINUTES` in `/etc/gha-runners/config.env` (`0` turns it off).

## Full disk

Jobs can only fill about 90% of the disk. The rest is a reserve file
(`/var/lib/gha-runners/disk-reserve`, 10% of the disk, 512 MB to 10 GB), so Docker,
the runners and the cleanup still have room to work when a job fills everything else.

- **Before every job**, `gha-cleanup` (built into the runner image) removes the
  workspaces of other repositories (they're wiped before their next job anyway). From
  80% disk it also removes unused Docker images, volumes and build cache, the [caches](caching.md), buildx
  builders of cancelled jobs, `/tmp` and the package caches in the runner's home (npm,
  pip, Go, Cargo, Gradle, Maven, NuGet, bun, pnpm). The runner image and the starting
  job's workspace are kept.
- **When the disk is full** (less than 1 GB free), the disk guard
  (`gha-runners-diskguard.service`, checks every 15 seconds) deletes the reserve and
  the workspaces of idle runners, restarts Docker if the full disk took it down,
  removes unused Docker data and runs `gha-cleanup` in every runner that's between
  jobs. Busy runners are left alone and clean up at their next job. Once there's
  room again, the reserve is set aside again.

The job that filled the disk still fails, but the runners keep running and the next
jobs get a clean disk. `gha-runners doctor` shows whether the reserve was released.
Set `DISK_RESERVE_PERCENT` in `/etc/gha-runners/config.env` to change the reserve
(`0` turns it off). Jobs can also call `gha-cleanup --force` themselves.

On ZFS, blocks that are only reserved or zero aren't really allocated, so there the
reserve is written with random data and takes real space in the pool.

## Image store

Docker 29 and later default to the containerd image store, which keeps
every image twice (compressed and unpacked): `full-plus` then takes ~22 GB instead of
~13 GB. New installs use the classic store. `gha-runners doctor` warns if a container
still uses the containerd store; `gha-runners migrate-storage` switches it. That stops
the runners, deletes all Docker images and rebuilds the runner image, so the runners
are offline for one image build.
