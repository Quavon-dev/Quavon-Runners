# Security model

> **Jobs can reach the LXC's Docker socket, which gives them root inside the
> LXC.** This is the usual trade-off for self-hosted runners with Docker.
> [Network isolation](install-proxmox.md#network-isolation) stops a compromised job from reaching
> the rest of your network, but it can still use the internet. Do not attach
> these runners to **public** repositories that run workflows from fork pull
> requests.

- Registration tokens are only passed to `config.sh` and are not saved (the bootstrap file is deleted).
- Registration and removal tokens reach `config.sh` through the environment
  (`ACTIONS_RUNNER_INPUT_TOKEN`), so they never appear in `ps`.
- In ephemeral mode the PAT is kept in `/etc/gha-runners/runners/<name>.pat`
  (root, mode 600) and **never enters the runner container**. The LXC mints a
  1-hour registration token from it and passes in only that token, which is
  unset before the runner starts. Jobs still have root on the LXC through the
  Docker socket, so give the PAT the narrowest scope you can. For organisations,
  use a fine-grained PAT with only **Self-hosted runners: write**.
- The [caches](caching.md) are shared by every job on the LXC, across repositories. A job
  can put poisoned files (package caches, Git objects) into a cache that a later job of
  another repository restores. The actions cache is scoped per repository, but jobs have
  root on the LXC and could change its files too, just like they could change the runner
  binaries for later jobs. Only attach repositories that trust each other.
- If Docker can't start containers in the LXC (a known AppArmor issue on some PVE
  versions), the installer offers `lxc.apparmor.profile: unconfined`, but only
  after you confirm it.
- `full-plus` runners allow io_uring in their seccomp profile (see [io_uring](images.md#io_uring)).

Without Proxmox there is no host firewall and jobs get root on the whole machine:
see [Install on Debian or Ubuntu › Security](install-linux.md#security).

Report vulnerabilities privately, see [SECURITY.md](../SECURITY.md).
