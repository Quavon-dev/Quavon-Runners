# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately
through [GitHub Security Advisories](https://github.com/Quavon-dev/Quavon-Runners/security/advisories/new)
(**Security → Report a vulnerability**).

Include what you found, how to reproduce it, the affected version (commit or
image tag) and the impact you expect. We will confirm receipt, keep you updated
while we work on a fix, and credit you in the advisory unless you prefer not to
be named.

## Supported versions

Only the latest commit on `main` and the images published from it to
`ghcr.io/quavon-dev/gha-runner` receive fixes.

## Scope

In scope:

- **Runner isolation**: a job escaping its runner container or the LXC beyond
  what is documented, reaching the Proxmox host, or bypassing the
  [network isolation](docs/install-proxmox.md#network-isolation) (LAN, host and IPv6 blocks).
- **Token handling**: registration, removal or PAT tokens leaking into command
  lines, logs, the runner container, the image or files with loose permissions.
- **Cache poisoning**: one repository writing to caches that another repository
  restores in a way not covered by the trust model in [security model](docs/security.md),
  or the actions cache serving entries across repository scopes.
- The installer, `gha-runners`, the systemd units, the runner image and the
  workflows in this repository.

Out of scope:

- Behaviour documented as a trade-off in the [security model](docs/security.md), for example jobs having
  root inside the LXC through the Docker socket, or jobs reaching the internet.
- Running these runners for public repositories that accept workflows from fork
  pull requests.
- Vulnerabilities in third-party software bundled in the image that are already
  fixed upstream; the image is rebuilt weekly.
