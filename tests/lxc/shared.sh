#!/usr/bin/env bash
# Shared cache across two LXC stand-ins (A = gha-lxc-test, B = gha-lxc-test-b),
# both with /shared mounted like install.sh share-cache does.
#   shared.sh setup   inside B: Docker and the gha-runners files
#   shared.sh         on the test machine, after integration.sh ran in A
# shellcheck disable=SC2034,SC2329  # used by the checks chk evaluates
set -uo pipefail
SH=/var/lib/gha-runners/shared

if [[ "${1:-}" == setup ]]; then
  set -e
  cp -r /src /opt/quavon-docker-runners
  mkdir -p /etc/docker
  echo '{ "features": { "containerd-snapshotter": false }, "storage-driver": "overlay2" }' >/etc/docker/daemon.json
  bash /opt/quavon-docker-runners/lxc/setup.sh docker
  bash /opt/quavon-docker-runners/lxc/setup.sh files
  printf 'REPO_DIR=/opt/quavon-docker-runners\nRUNNER_FLAVOR=standard\nRUNNER_IMAGE=quavon/gha-runner:standard\n' >/etc/gha-runners/config.env
  exit 0
fi

A=gha-lxc-test B=gha-lxc-test-b
pass=0 fail=0
ok()   { echo "ok   $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL $1"; fail=$((fail + 1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n== %s\n' "$*"; }
in_ct() { docker exec "$1" bash -c "$2"; }
wait_for() { local _; for _ in $(seq 1 "$1"); do eval "$2" && return 0; sleep 1; done; return 1; }
serves() { in_ct "$1" "docker inspect -f '{{.State.Running}}' gha-cache-$2 2>/dev/null | grep -qx true"; }
health() { in_ct "$1" 'curl -fsS -o /dev/null --max-time 3 "http://$(ip -4 -o addr show docker0 | awk "{ sub(\"/.*\", \"\", \$4); print \$4 }"):29171/health"'; }

section "shared cache: one LXC serves, the other forwards"
in_ct "$A" "echo 2 >/shared/budget-gb"
in_ct "$A" "mkdir -p $SH && mount --bind /shared $SH && gha-runners _caches"
wait_for 30 'serves "$A" actions && serves "$A" mirror'
in_ct "$B" "mkdir -p $SH && mount --bind /shared $SH && gha-runners _caches"
chk "A serves the actions cache and the mirror" 'serves "$A" actions && serves "$A" mirror'
chk "A's caches live in the shared directory" 'in_ct "$A" "test -S $SH/run/actions.sock && test -e $SH/actions-cache/cache.db"'
chk "A's old local caches are gone" 'in_ct "$A" "! test -e /var/lib/gha-runners/actions-cache && ! test -e /var/lib/gha-runners/mirror-cache"'
chk "B reaches the actions cache through the shared socket" 'wait_for 20 "health $B"'
chk "B runs no cache server of its own" '! serves "$B" actions && ! serves "$B" mirror'
in_ct "$B" "docker image rm busybox >/dev/null 2>&1; docker pull -q busybox >/dev/null"
chk "B's Docker pulls go through the shared mirror" 'in_ct "$A" "find $SH/mirror-cache -type f -name data | grep -q ."'
in_ct "$B" "gha-runners doctor" >/tmp/doctor-b.log 2>&1
chk "doctor in B shows the shared caches" 'grep -q "shared caches" /tmp/doctor-b.log && grep -q "actions cache  : active, .*served by another LXC" /tmp/doctor-b.log'

section "failover"
in_ct "$A" "systemctl stop gha-runners-cache@actions"
chk "B takes over when A's server stops" 'wait_for 30 "serves $B actions"'
chk "B serves the cache A wrote (same database)" 'wait_for 20 "health $B" && in_ct "$B" "test -e $SH/actions-cache/cache.db"'
in_ct "$A" "systemctl start gha-runners-cache@actions"
chk "A forwards to B after its restart" 'wait_for 20 "health $A" && ! serves "$A" actions'

section "runner container in shared mode"
in_ct "$A" '
  source <(sed -n "/^install_runner_binaries()/,/^}/p;/^latest_runner_version()/,/^}/p;/^runner_arch()/,/^}/p;/^info()/p;/^die()/p" /usr/local/bin/gha-runners)
  dir=/srv/gha-runners/shared-1
  CACHE_DIR=/var/cache/gha-runners RUNNER_UID=1001 install_runner_binaries "$dir" >/dev/null
  echo "{\"agentId\":1,\"agentName\":\"shared-1\",\"gitHubUrl\":\"https://github.com/o/r\",\"workFolder\":\"_work\"}" >"$dir/.runner"
  chown -R 1001:1001 "$dir"
  printf "RUNNER_NAME=shared-1\nRUNNER_DIR=%s\nGITHUB_URL=https://github.com/o/r\nRUNNER_LABELS=\nRUNNER_GROUP=\nRUNNER_EPHEMERAL=0\n" "$dir" >/etc/gha-runners/runners/shared-1.env
  chmod 600 /etc/gha-runners/runners/shared-1.env
  systemctl start gha-runner@shared-1'
wait_for 30 'in_ct "$A" "docker inspect gha-shared-1 >/dev/null 2>&1"'
insp="$(in_ct "$A" "docker inspect gha-shared-1")"
chk "package caches come from the shared directory" 'grep -q "$SH/package-cache/cache:/home/runner/.cache" <<<"$insp" && grep -q "\"GHA_SHARED_CACHE=1\"" <<<"$insp"'
chk "the shared Git store is mounted" 'grep -q "\"$SH/git:$SH/git\"" <<<"$insp" && grep -q "\"GHA_GIT_SHARED=$SH/git\"" <<<"$insp"'
chk "the runner uses the shared actions cache" 'grep -q "ACTIONS_RESULTS_URL=http://" <<<"$insp"'

section "shared Git checkout cache"
d=/srv/gha-runners/shared-1
in_ct "$A" "docker exec gha-shared-1 bash -c '
  set -e; git config --global user.email t@t; git config --global user.name t
  git init -q --bare $d/_work/_up/o/r && git init -q /tmp/src && cd /tmp/src && echo 1 >f && git add f && git commit -qm 1
  git push -q file://$d/_work/_up/o/r HEAD:main
  mkdir -p $d/_work/r/r && cd $d/_work/r/r && git init -q && git remote add origin file://$d/_work/_up/o/r
  git fetch -q --depth=1 origin +main:refs/remotes/origin/main && git checkout -q -B main refs/remotes/origin/main'" >/tmp/shared-git.log 2>&1
genv="-e GITHUB_REPOSITORY=o/r -e GITHUB_SERVER_URL=file://$d/_work/_up"
in_ct "$A" "docker exec $genv -e GITHUB_WORKSPACE=$d/_work/r/r gha-shared-1 /usr/local/bin/gha-git-cache save" >>/tmp/shared-git.log 2>&1
chk "a saved .git is copied to the shared store" 'in_ct "$A" "test -d $SH/git/o/r.git/objects && test -d $d/_git/o/r.git/objects"'
in_ct "$A" "docker exec $genv -e RUNNER_DIR=$d/other -e GITHUB_WORKSPACE=$d/other/_work/r/r gha-shared-1 bash -c 'mkdir -p $d/other/_work && /usr/local/bin/gha-git-cache restore && cd $d/other/_work/r/r && git reset -q --hard HEAD && cat f'" >>/tmp/shared-git.log 2>&1
chk "a runner without its own copy starts from the shared one" 'tail -1 /tmp/shared-git.log | grep -qx 1' || tail -5 /tmp/shared-git.log

section "budget"
in_ct "$A" "echo 1 >/shared/budget-gb && fallocate -l 900M $SH/package-cache/cache/big"
in_ct "$B" "gha-runners prune" >/tmp/prune-b.log 2>&1
chk "over 80% of the budget the package and Git caches are cleared" 'in_ct "$A" "! test -e $SH/package-cache/cache/big && ! test -e $SH/git/o"'
chk "the mirror is only cleared by the LXC serving it" 'in_ct "$A" "find $SH/mirror-cache -type f -name data | grep -q ."'
chk "B keeps the cache server images for a takeover" 'in_ct "$B" "docker image inspect gha-runners/cache-actions:pinned gha-runners/cache-mirror:pinned >/dev/null"'
chk "the actions cache stays" 'in_ct "$A" "test -e $SH/actions-cache/cache.db"'

printf '\nshared cache: %s passed, %s failed\n' "$pass" "$fail"
exit $(( fail > 0 ))
