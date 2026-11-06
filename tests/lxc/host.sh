#!/usr/bin/env bash
# Runs INSIDE a fresh systemd test container (a plain Debian VM): install.sh host
# without Proxmox, the shared-Docker guard and the re-run as an update.
set -uo pipefail
pass=0 fail=0
ok()   { echo "ok   $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL $1"; fail=$((fail + 1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n== %s\n' "$*"; }
TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAA

mkdir -p /etc/docker
echo '{ "features": { "containerd-snapshotter": false }, "storage-driver": "overlay2" }' >/etc/docker/daemon.json

host_install() {   # host_install <log> [VAR=value...]
  local log="$1"; shift
  rm -f /tmp/gha-runners-install-*.log
  env NONINTERACTIVE=1 GH_URL=https://github.com/quavon-dev/quavon-docker-runners GH_TOKEN="$TOKEN" \
    RUNNER_COUNT=2 SIZE=small RUNNER_LABELS=docker "$@" bash /src/install.sh host 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >"$log"
  return "${PIPESTATUS[0]}"
}

section "install.sh host on a plain Debian machine (invalid token: stops at the registration)"
host_install /tmp/host1.log; rc=$?
chk "preflight accepts Debian $(. /etc/os-release; echo "$VERSION_ID")" 'grep -q "✔ Debian" /tmp/host1.log'
chk "scripts deployed to /opt" '[[ -f /opt/quavon-docker-runners/lxc/setup.sh ]] && grep -q "Deployed scripts from /src" /tmp/host1.log'
chk "Docker installed" 'grep -q "✔ Installed Docker" /tmp/host1.log && systemctl is-active --quiet docker'
chk "CLI, units and caches set up" 'command -v gha-runners >/dev/null && systemctl is-enabled --quiet gha-runners-prune.timer && systemctl is-active --quiet gha-runners-cache@actions'
chk "registration reached GitHub and failed (rc=$rc)" '[[ $rc != 0 ]] && grep -q "Registering runner(s) failed" /tmp/host1.log'
chk "config written, Docker not shared" 'grep -q "RUNNER_CPUS=1" /etc/gha-runners/config.env && ! grep -q SHARED_DOCKER /etc/gha-runners/config.env'
chk "bootstrap with token deleted" '[[ ! -e /root/.gha-bootstrap.env ]]'
chk "token never in output or log" '! grep -q "$TOKEN" /tmp/host1.log /tmp/gha-runners-install-*.log'

section "re-run after a failed install starts over (own containers don't count as shared)"
host_install /tmp/host2.log
chk "re-run not refused" '! grep -q "already has containers" /tmp/host2.log && grep -q "Registering runner(s) failed" /tmp/host2.log'

section "Docker with other workloads"
docker run -q -d --restart unless-stopped --name user-app busybox sleep 3600 >/dev/null
host_install /tmp/host3.log; rc=$?
chk "refused without SHARED_DOCKER=1 (rc=$rc)" '[[ $rc != 0 ]] && grep -q "already has containers or volumes" /tmp/host3.log && ! grep -q "Installing Docker" /tmp/host3.log'
host_install /tmp/host4.log SHARED_DOCKER=1
chk "SHARED_DOCKER=1 continues and is kept in config.env" 'grep -q "Registering runner(s)" /tmp/host4.log && grep -qx SHARED_DOCKER=1 /etc/gha-runners/config.env'
sleep 61
echo LEFTOVER_MINUTES=1 >>/etc/gha-runners/config.env
gha-runners prune >/tmp/prune.log 2>&1
sed -i '/^LEFTOVER_MINUTES=/d' /etc/gha-runners/config.env
chk "prune keeps the user's running container" '[[ $(docker inspect -f "{{.State.Running}}" user-app 2>/dev/null) == true ]]'
docker rm -f user-app >/dev/null 2>&1

section "re-run on an installed machine = update"
install -d -m 0700 /etc/gha-runners/runners
printf 'RUNNER_NAME=x\nRUNNER_DIR=/srv/gha-runners/x\n' >/etc/gha-runners/runners/x.env
host_install /tmp/host5.log
chk "re-run runs gha-runners update" 'grep -q "re-run install.sh from a clone\|Updating /opt/quavon-docker-runners" /tmp/host5.log && ! grep -q "Installing Docker" /tmp/host5.log'
rm -f /etc/gha-runners/runners/x.env

printf '\nhost install: %s passed, %s failed\n' "$pass" "$fail"
exit $(( fail > 0 ))
