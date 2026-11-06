# Development

See [CONTRIBUTING.md](../CONTRIBUTING.md) for how to propose changes.

## Tests

Everything runs in Docker on any machine. No Proxmox host is needed.

```bash
tests/run.sh         # shellcheck + unit tests + 26 end-to-end installer runs
tests/lxc/run.sh     # inside-the-LXC side for real: Docker, systemd units, image build, runner container, shared cache across two LXCs, install.sh host on a plain Debian machine
```

- **End-to-end tests** start `install.sh` exactly like the one-liner (`bash -c "$(…)"`) against a
  fake Proxmox (`tests/fake-pve/`), and type into the real whiptail dialogs through a
  pseudo-terminal. They cover:
  - the normal path, the `separate` layout with static IPs and VLAN, LAN mode, and ephemeral mode
  - invalid input, runner-name clashes, and a disabled datacenter firewall
  - Docker or AppArmor failures, a leaky firewall, no network, and DHCP handing out the host's IP
  - Esc and Ctrl+C, a dropped session during the image build, a too-small terminal, a hanging `pvesh`, and non-interactive mode
  - `update` and `share-cache` on existing LXCs: waiting for running jobs, one LXC after another, the mount, and stopping at a failed update

  They also check that no token ever appears in a command line or the log.
- **LXC integration** boots Debian 13 with systemd and runs the real `setup.sh`,
  `gha-runners`, systemd units and image build. With `GH_TEST_URL` and `GH_TEST_TOKEN`
  set, it also registers a real runner.

## Layout

```text
install.sh                 Proxmox host wizard (pct create / push / exec)
lxc/setup.sh               provisioning inside the LXC (Docker, CLI, registration)
lxc/gha-runners            management CLI
lxc/run-container.sh       docker run wrapper used by gha-runner@.service
lxc/systemd/               runner template unit, cache services, hourly prune timer, disk guard
lxc/seccomp/io-uring.json  seccomp profile for full-plus runners (Docker default + io_uring)
image/Dockerfile           runner image (FLAVOR=standard|full|full-plus)
image/scripts/NN-*.sh      one build step per toolchain ("# flavors:" header)
image/entrypoint.sh        ephemeral re-registration, env capture, run.sh
image/hooks/               job-started / job-completed cleanup hooks
image/tools/gha-cleanup    disk cleanup inside the runner (hooks, disk guard, jobs)
image/tools/gha-patch-runner  keeps the runner on the local actions cache
image/tools/gha-git-cache     keeps .git between jobs for fast checkouts
.github/workflows/image.yml   publishes the prebuilt images to GHCR
.github/workflows/ci.yml      tests, actionlint, shellcheck, hadolint, zizmor, gitleaks
.github/workflows/codeql.yml  CodeQL for the workflows and the Python tests
.github/workflows/scorecard.yml  OpenSSF Scorecard
.github/workflows/benchmark.yml  GitHub-hosted vs. self-hosted benchmark
benchmarks/                benchmark data, collect/summarize scripts, chart.py
docs/                      documentation; docs/assets/ holds the README visuals
tests/                     unit + end-to-end tests (fake Proxmox) and LXC integration test
```

## Docs visuals

`docs/assets/banner.svg` and `docs/assets/architecture.svg` follow the quavon.de style
(canvas `#0A0A0A`, mint `#00FFC8`, cyan `#00B4D8`, Outfit). They sit on their own dark
card, so they read the same on GitHub's light and dark themes.

`docs/assets/benchmark.svg` is generated from `benchmarks/summary.json`:

```bash
python3 benchmarks/chart.py
```
