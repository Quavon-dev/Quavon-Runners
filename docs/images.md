# Runner images

Each runner is a Docker container whose image is modeled on GitHub's hosted
`ubuntu-24.04` runner: user `runner` (uid 1001) with passwordless `sudo`,
`/opt/hostedtoolcache` and `ImageOS=ubuntu24`, so `actions/setup-*` work.

## Flavors

| `standard` (~3 GB) | `full` (~13 GB), everything in standard plus |
|---|---|
| build-essential, cmake, ninja, git (latest) + LFS, gh | Go (latest), Temurin JDK 11/17/21/25, Maven, Gradle, Ant |
| Docker CLI + buildx + compose | .NET SDK 8/9/10 |
| Python 3 + pip + pipx | Rust (rustup, clippy, rustfmt) |
| Node.js 22 + npm, yarn, pnpm | Ruby + bundler, PHP + Composer |
| jq, yq, kubectl, helm, shellcheck, zip/7z/zstd … | clang/lld/lldb, gfortran, MySQL/PostgreSQL clients, ImageMagick |
| | PowerShell, Chrome + chromedriver, Firefox + geckodriver |
| | AWS CLI v2, Azure CLI, Google Cloud CLI, ansible, kind |

Change the flavor later with `gha-runners build --flavor full && gha-runners restart`
(or `--flavor full-plus`).

## Prebuilt images

The image is pulled from `ghcr.io/quavon-dev/gha-runner:<flavor>-<tree>`, where `<tree>`
is the git tree hash of `image/`. Only an image built from exactly the scripts in the LXC
is used. If `image/` has local changes (a fork, an edit) or CI hasn't published that
version yet, the image is built locally instead. `gha-runners build --local` always
builds locally; `PREBUILT_IMAGE=` in `/etc/gha-runners/config.env` turns pulling off, or
points it at your own registry (see [Forking](forking.md)). `.github/workflows/image.yml` publishes all three
flavors on every change to `image/` and every Monday, so security updates arrive with
`gha-runners update`.

`full` and `full-plus` are built from thousands of small files. On a host with only
spinning disks (HDD) or less than 8 GB RAM a local build can take 1-2 hours, so the
installer asks first. On HDDs, ZFS storage is much faster than LVM-thin: the installer
turns off sync writes there (see [Sizing](install-proxmox.md#sizing)).

## full-plus

`full-plus` (~15 GB) is `full` plus a pinned backend/CI toolchain, so workflows don't
download or `go install` these on every run. Every download is checked against its
published SHA-256; the Go tools are built with `go install` at the exact tag.

| Tool | Version |
|---|---|
| bun | 1.3.14 |
| Valkey (`valkey-server`, `valkey-cli`; `redis-server`/`redis-cli` link to them) | 8.1.10 |
| nats-server | v2.14.6 |
| openfga | v1.19.0 |
| goose | v3.27.3 |
| OpenBao (`bao`) | 2.1.0 |
| Temporal CLI | 1.8.2 |
| TigerBeetle | 0.16.78 |
| typst | 0.15.1 |
| buf, protoc-gen-go, protoc-gen-connect-go | v1.47.2, v1.36.12, v1.20.0 |
| golangci-lint | v2.12.2 |
| gosec | v2.29.0 |
| gitleaks | 8.30.1 |
| actionlint | 1.7.12 |
| kubeconform | 0.8.0 |
| lsof | Ubuntu's |

Versions and digests live in `image/scripts/58-ci-stack.sh`. Valkey isn't started
as a service, so nothing holds port 6379.

### io_uring

TigerBeetle needs io_uring, and Docker's default seccomp profile
blocks it. `full-plus` runners therefore run under Docker's default profile plus
`io_uring_setup`, `io_uring_enter` and `io_uring_register`
(`lxc/seccomp/io-uring.json`), never `unconfined`. io_uring has a history of kernel
bugs, so this widens the attack surface a little for jobs on these runners. To turn it
off, add `RUNNER_IO_URING=0` to `/etc/gha-runners/config.env` and run `gha-runners restart`.

## Third-party licenses

The runner images bundle third-party software (Ubuntu packages, language toolchains,
browsers, cloud CLIs, the GitHub Actions runner) under their own licenses. The cache
server ([github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server),
MIT) and the Docker Hub mirror (`registry`, Apache-2.0) run as their unmodified upstream images.
