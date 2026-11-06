#!/usr/bin/env bash
# Builds systemd Debian 13 containers (stand-ins for the LXCs) and runs the
# in-container integration test with real Docker inside, the shared cache
# test across two of them, and install.sh host on a third (a plain VM).
set -euo pipefail
cd "$(dirname "$0")/../.."
docker build -q -t gha-lxc-test tests/lxc >/dev/null
docker rm -f gha-lxc-test gha-lxc-test-b gha-lxc-test-c >/dev/null 2>&1 || true
docker volume rm gha-lxc-test-shared gha-lxc-test-c-docker >/dev/null 2>&1 || true
for v in gha-lxc-test-docker gha-lxc-test-containerd gha-lxc-test-b-docker gha-lxc-test-c-docker gha-lxc-test-shared; do docker volume create "$v" >/dev/null; done
start() {   # start <name> <docker volume>
  docker run -d --name "$1" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$2":/var/lib/docker -v gha-lxc-test-shared:/shared \
    -v "$PWD":/src:ro gha-lxc-test >/dev/null
}
start gha-lxc-test gha-lxc-test-docker
start gha-lxc-test-b gha-lxc-test-b-docker
start gha-lxc-test-c gha-lxc-test-c-docker
trap 'docker rm -f gha-lxc-test gha-lxc-test-b gha-lxc-test-c >/dev/null 2>&1' EXIT
sleep 5
docker exec gha-lxc-test-b bash /src/tests/lxc/shared.sh setup >/tmp/gha-lxc-test-b.log 2>&1 &
setup_b=$!
docker exec gha-lxc-test-c bash /src/tests/lxc/host.sh >/tmp/gha-lxc-test-c.log 2>&1 &
host_c=$!
rc=0
docker exec -e GH_TEST_URL="${GH_TEST_URL:-}" -e GH_TEST_TOKEN="${GH_TEST_TOKEN:-}" gha-lxc-test bash /src/tests/lxc/integration.sh || rc=$?
wait "$setup_b" || { echo "FAIL second LXC setup"; tail -20 /tmp/gha-lxc-test-b.log; exit 1; }
bash tests/lxc/shared.sh || rc=$?
wait "$host_c" || rc=1
cat /tmp/gha-lxc-test-c.log
exit "$rc"
