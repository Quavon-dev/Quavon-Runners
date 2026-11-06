#!/usr/bin/env bash
# Runs INSIDE the systemd test container: exercises lxc/setup.sh, gha-runners,
# the systemd units, the image build and the runner container for real.
# A real GitHub registration is optional (GH_TEST_URL + GH_TEST_TOKEN).
set -uo pipefail
REPO=/opt/quavon-docker-runners
pass=0 fail=0
ok()   { echo "ok   $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL $1"; fail=$((fail + 1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n== %s\n' "$*"; }

cp -r /src "$REPO"

# Test machine only: nested Docker on Docker Desktop can't use the containerd
# overlay snapshotter. setup.sh keeps an existing daemon.json, so set overlay2.
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'J'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "3" },
  "features": { "containerd-snapshotter": false }, "storage-driver": "overlay2" }
J

section "setup.sh docker"
bash "$REPO/lxc/setup.sh" docker >/tmp/docker.log 2>&1; rc=$?
chk "docker installed + test container ran (rc=$rc)" '[[ $rc == 0 ]]'
chk "docker daemon active" 'systemctl is-active --quiet docker'
chk "log rotation configured" 'grep -q max-size /etc/docker/daemon.json'
chk "build cache capped" 'jq -e ".builder.gc.defaultMaxUsedSpace" /etc/docker/daemon.json >/dev/null'
chk "existing daemon.json settings kept" 'jq -e ".\"storage-driver\" == \"overlay2\"" /etc/docker/daemon.json >/dev/null'

section "setup.sh register (with an invalid token: must fail cleanly)"
cat >/root/.gha-bootstrap.env <<B
GH_URL=https://github.com/Quavon-dev/Quavon-Runners
GH_TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAAAA
GH_PAT=''
RUNNER_EPHEMERAL=0
RUNNER_PREFIX=itest
RUNNER_COUNT=2
RUNNER_LABELS=docker
RUNNER_GROUP=''
RUNNER_FLAVOR=standard
RUNNER_CPUS=2
RUNNER_MEM=2048
B
# Same conditions as `pct exec` on the reporter's host: minimal PATH and the
# host's locale (en_US.UTF-8, not installed in the container).
env -i HOME=/root PATH=/usr/bin:/bin LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  bash "$REPO/lxc/setup.sh" register /root/.gha-bootstrap.env >/tmp/register.log 2>&1; rc=$?
chk "gha-runners found despite minimal PATH" '! grep -q "command not found" /tmp/register.log'
chk "no locale warnings" '! grep -qiE "setting locale failed|cannot set LC_" /tmp/register.log'
chk "registration reached GitHub" 'grep -q "Http response code" /tmp/register.log'
chk "invalid token -> non-zero exit (rc=$rc)" '[[ $rc != 0 && $rc != 4 ]]'
chk "bootstrap with token deleted" '[[ ! -e /root/.gha-bootstrap.env ]]'
chk "no half-registered runner dir left" '[[ -z "$(ls -A /srv/gha-runners)" ]]'
chk "token never printed by registration" '! grep -q "AAAAAAAAAAAAAAAAAAAAAAAAAAAA" /tmp/register.log'
chk "CLI + units installed" 'command -v gha-runners >/dev/null && [[ -f /etc/systemd/system/gha-runner@.service ]]'
chk "prune timer enabled" 'systemctl is-enabled --quiet gha-runners-prune.timer'
chk "disk guard enabled" 'systemctl is-enabled --quiet gha-runners-diskguard.service'
chk "runner user uid 1001" '[[ $(id -u runner) == 1001 ]]'
chk "config written" 'grep -q "RUNNER_IMAGE=quavon/gha-runner:standard" /etc/gha-runners/config.env'
chk "runner tarball downloaded + cached" 'ls /var/cache/gha-runners/actions-runner-linux-*.tar.gz >/dev/null 2>&1'
echo "     --- registration output (tail) ---"; tail -8 /tmp/register.log | sed 's/^/     /'

section "caches"
bip="$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')"
cache_url="http://${bip}:29171"
for _ in $(seq 1 60); do curl -fsS -o /dev/null "$cache_url/health" 2>/dev/null && break; sleep 1; done
chk "actions cache answers on docker0" 'curl -fsS -o /dev/null "$cache_url/health"'
chk "actions cache reachable from a bridge container" 'docker run --rm busybox wget -qO /dev/null "$cache_url/health"'
chk "actions cache rejects requests without a job token" '[[ $(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{}" "$cache_url/twirp/github.actions.results.api.v1.CacheService/GetCacheEntryDownloadURL") == 401 ]]'
chk "actions cache not on loopback" '! curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:29171/health'
chk "docker hub mirror configured" 'jq -e ".\"registry-mirrors\" == [\"http://${bip}:29172\"]" /etc/docker/daemon.json >/dev/null'
chk "docker trusts the ghcr.io mirror over http" 'jq -e ".\"insecure-registries\" == [\"${bip}:29174\"]" /etc/docker/daemon.json >/dev/null'
for port in 29172 29174 29175 29176; do
  for _ in $(seq 1 60); do curl -fsS -o /dev/null "http://${bip}:${port}/v2/" 2>/dev/null && break; sleep 1; done
done
chk "registry mirrors answer on docker0" '(for p in 29172 29174 29175 29176; do curl -fsS -o /dev/null "http://${bip}:$p/v2/" || exit 1; done)'
chk "apt proxy answers on docker0" 'curl -fsS -o /dev/null "http://${bip}:29173/health"'
chk "mirrors reachable from a bridge container" 'docker run --rm busybox sh -c "wget -qO /dev/null http://${bip}:29172/v2/ && wget -qO /dev/null http://${bip}:29174/v2/ && wget -qO /dev/null http://${bip}:29173/health"'
chk "no cache on loopback or all interfaces" '! ss -ltnH | awk "{ print \$4 }" | grep -E ":2917[0-9]$" | grep -qv "^${bip}:"'
docker image rm busybox >/dev/null 2>&1; docker pull -q busybox >/dev/null 2>&1
chk "docker pulls go through the mirror" '[[ -n "$(find /var/lib/gha-runners/mirror-cache -type f -name data | head -1)" ]]'
(source <(sed '$d' /usr/local/bin/gha-runners); load_config; pull_through_mirror ghcr.io/containerd/busybox:1.36) >/tmp/ghcr.log 2>&1; rc=$?
chk "ghcr.io image pulled through the ghcr mirror (rc=$rc)" '[[ $rc == 0 ]] && docker image inspect ghcr.io/containerd/busybox:1.36 >/dev/null && [[ -d /var/lib/gha-runners/ghcr-cache/docker/registry/v2/repositories/containerd/busybox ]]'
chk "the mirror's name is not left behind" '! docker images --format "{{.Repository}}" | grep -q 29174'
accept="Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
chk "quay.io and mcr.microsoft.com mirrors fetch manifests" 'curl -fsS -o /dev/null -H "$accept" "http://${bip}:29175/v2/prometheus/busybox/manifests/latest" && curl -fsS -o /dev/null -H "$accept" "http://${bip}:29176/v2/mcr/hello-world/manifests/latest"'
curl -s -D /tmp/private.h -o /dev/null -H "Authorization: Basic $(printf itest:dummy | base64)" "http://${bip}:29174/v2/quavon-dev/itest-private/manifests/latest"
chk "mirrors never ask for credentials and serve nothing private" 'grep -q "^HTTP/1.1 404" /tmp/private.h && ! grep -qi "^www-authenticate" /tmp/private.h'
docker stats --no-stream --format '     {{.Name}}: {{.MemUsage}}' gha-cache-actions gha-cache-mirror gha-cache-apt gha-cache-ghcr gha-cache-quay gha-cache-mcr

section "gha-runners build (real image build, standard)"
start=$SECONDS
gha-runners build --flavor standard >/tmp/build.log 2>&1; rc=$?
chk "image built in $((SECONDS - start))s (rc=$rc)" '[[ $rc == 0 ]] && docker image inspect quavon/gha-runner:standard >/dev/null'
[[ $rc == 0 ]] || tail -20 /tmp/build.log

section "runner service (real registration or simulated)"
name=itest-1 dir=/srv/gha-runners/r1
if [[ -n "${GH_TEST_TOKEN:-}" ]]; then
  GHA_TOKEN="$GH_TEST_TOKEN" gha-runners add --name "$name" --url "$GH_TEST_URL" --labels itest --no-start >/tmp/add.log 2>&1
  chk "registered with GitHub" '[[ -f $dir/.runner ]]'
else
  # gha-runners add with a simulated registration: real binaries + fake registration files
  (source <(sed '$d' /usr/local/bin/gha-runners)
   runner_config() { echo '{"agentId":1,"agentName":"itest-1","serverUrl":"https://pipelinesghubeus1.actions.githubusercontent.com/x/","gitHubUrl":"https://github.com/Quavon-dev/Quavon-Runners","workFolder":"_work"}' >"$1/.runner"; chown 1001:1001 "$1/.runner"; }
   cmd_add --name "$name" --url https://github.com/Quavon-dev/Quavon-Runners --token AAAAAAAAAAAAAAAAAAAA --no-start) >/tmp/add.log 2>&1
fi
chk "a new runner gets the first slot directory" '[[ -x $dir/run.sh && $(stat -c %u "$dir") == 1001 ]] && grep -qx "RUNNER_DIR=$dir" /etc/gha-runners/runners/$name.env' || tail -5 /tmp/add.log
systemctl start "gha-runner@$name"
for _ in $(seq 1 30); do docker inspect "gha-$name" >/dev/null 2>&1 && break; sleep 1; done
insp="$(docker inspect "gha-$name" 2>/dev/null || true)"
chk "runner unit active (not restarting)" 'systemctl is-active --quiet "gha-runner@$name"'
chk "runner container started" 'docker ps --format "{{.Names}}" | grep -qx "gha-$name"'
chk "runs as uid 1001" 'grep -q "\"User\": \"1001:1001\"" <<<"$insp"'
chk "host network" 'grep -q "\"NetworkMode\": \"host\"" <<<"$insp"'
chk "docker socket mounted" 'grep -q "/var/run/docker.sock:/var/run/docker.sock" <<<"$insp"'
chk "runner dir at identical path" 'grep -q "\"$dir:$dir\"" <<<"$insp"'
chk "cpu/memory caps applied" 'grep -q "\"NanoCpus\": 2000000000" <<<"$insp" && grep -q "\"Memory\": 2147483648" <<<"$insp"'
chk "parallelism hints match the cpu cap" 'grep -q "\"GOMAXPROCS=2\"" <<<"$insp" && grep -q "\"PYTEST_XDIST_AUTO_NUM_WORKERS=2\"" <<<"$insp"'
chk "runner points at the local actions cache" 'grep -q "\"ACTIONS_RESULTS_URL=$cache_url/\"" <<<"$insp"'
chk "package caches mounted" 'grep -q "/var/lib/gha-runners/package-cache/cache:/home/runner/.cache" <<<"$insp" && grep -q "\"GOMODCACHE=/home/runner/.cache/go-mod\"" <<<"$insp"'
chk "tool cache shared by all runners, Go modules writable" 'grep -q "/var/lib/gha-runners/package-cache/toolcache:/opt/hostedtoolcache" <<<"$insp" && grep -q "\"GOFLAGS=-modcacherw\"" <<<"$insp"'
chk "runner gets the registry mirrors for buildx" 'grep -q "\"GHA_REGISTRY_MIRRORS=docker.io=${bip}:29172 ghcr.io=${bip}:29174 quay.io=${bip}:29175 mcr.microsoft.com=${bip}:29176\"" <<<"$insp"'
chk "no PAT/token in container env" '! grep -qE "GITHUB_PAT|GHA_TOKEN" <<<"$insp"'
docker exec "gha-$name" bash -lc 'id; docker version --format "docker-cli {{.Client.Version}} / daemon {{.Server.Version}}"; sudo -n true && echo sudo-ok' >/tmp/inrunner.log 2>&1
chk "docker usable from runner container" 'grep -q "daemon" /tmp/inrunner.log'
chk "passwordless sudo in runner" 'grep -q sudo-ok /tmp/inrunner.log'
# the same-path trick: a job container mounts a path from the runner dir
docker exec "gha-$name" bash -c "mkdir -p $dir/_work/t && echo hello >$dir/_work/t/f && docker run --rm -v $dir/_work/t:/w busybox cat /w/f" >/tmp/samepath.log 2>&1
chk "container jobs see runner workspace (same-path mount)" 'grep -qx hello /tmp/samepath.log'
sleep 8
chk "runner binary patched to keep the cache URL" 'LC_ALL=C grep -qaP "$(printf %s ACTIONS_RESULTS_ORL | sed "s/./&\\\\x00/g")" "$dir/bin/Runner.Worker.dll"'
docker exec "gha-$name" bash -c 'touch ~/.cache/itest-pkg && pip download -q --no-deps -d /tmp/p six >/dev/null 2>&1; true'
chk "package cache lands on the LXC" '[[ -e /var/lib/gha-runners/package-cache/cache/itest-pkg && $(stat -c %u /var/lib/gha-runners/package-cache/cache/itest-pkg) == 1001 ]]'
journalctl -u "gha-runner@$name" --no-pager -n 80 >/tmp/runner-journal.log
chk "env.sh captured image PATH for jobs" 'grep -q /opt/pipx_bin "$dir/.path"'
chk "runner process actually launched (Runner.Listener)" 'grep -qiE "Runner|Listener|Connected|credentials|Error" /tmp/runner-journal.log'
grep -iE "listening|connected|error|exception" /tmp/runner-journal.log | head -4 | sed 's/^/     /'

section "apt proxy in the runner"
chk "apt uses the proxy for http repositories" '[[ $(docker exec "gha-$name" /usr/local/bin/gha-apt-proxy http://archive.ubuntu.com/ubuntu/) == "http://${bip}:29173" ]]'
chk "https repositories and IP addresses go direct" '[[ $(docker exec "gha-$name" /usr/local/bin/gha-apt-proxy https://download.docker.com/linux/) == DIRECT && $(docker exec "gha-$name" /usr/local/bin/gha-apt-proxy http://10.0.0.1/debian/) == DIRECT ]]'
docker exec "gha-$name" bash -c 'sudo apt-get update -q && sudo apt-get install -y -q --download-only cowsay && sudo apt-get clean' >/tmp/apt.log 2>&1; rc=$?
chk "apt-get through the proxy (rc=$rc)" '[[ $rc == 0 ]] && [[ -n "$(find /var/lib/gha-runners/apt-cache -type f | head -1)" ]]' || tail -5 /tmp/apt.log
systemctl stop gha-runners-cache@apt
chk "proxy stopped: apt goes direct" '[[ $(docker exec "gha-$name" /usr/local/bin/gha-apt-proxy http://archive.ubuntu.com/ubuntu/) == DIRECT ]]'
docker exec "gha-$name" bash -c 'sudo apt-get update -q && sudo apt-get install -y -q --download-only cowsay && sudo apt-get clean' >/tmp/apt.log 2>&1; rc=$?
chk "proxy stopped: apt-get still works (rc=$rc)" '[[ $rc == 0 ]]' || tail -5 /tmp/apt.log
systemctl start gha-runners-cache@apt

section "buildx builders use the mirrors"
docker exec "gha-$name" bash -c "
  set -e
  docker buildx create --name builder-itest --driver docker-container --buildkitd-flags '--allow-insecure-entitlement security.insecure --allow-insecure-entitlement network.host' --use
  docker buildx inspect --bootstrap builder-itest
  printf 'FROM alpine:3.20\nFROM ghcr.io/containerd/alpine:3.14.0\nCOPY --from=0 /etc/alpine-release /hub\nRUN cat /hub\n' | docker buildx build --builder builder-itest -" >/tmp/buildx.log 2>&1; rc=$?
chk "builder created like setup-buildx-action got the mirror config" 'docker exec buildx_buildkit_builder-itest0 cat /etc/buildkit/buildkitd.toml 2>/dev/null | grep -q "${bip}:29174"'
chk "builder pulls Docker Hub images through the mirror (rc=$rc)" '[[ $rc == 0 && -d /var/lib/gha-runners/mirror-cache/docker/registry/v2/repositories/library/alpine ]]' || tail -15 /tmp/buildx.log
chk "builder pulls ghcr.io images through the ghcr mirror" '[[ -d /var/lib/gha-runners/ghcr-cache/docker/registry/v2/repositories/containerd/alpine ]]'
docker exec "gha-$name" docker buildx rm builder-itest >/dev/null 2>&1

section "job hooks"
docker exec "gha-$name" bash -c "sudo mkdir -p $dir/_work/_temp && sudo touch $dir/_work/_temp/root-file"
docker run -d --name itest-leftover -v "$dir/_work/t:/w" busybox sleep 600 >/dev/null
docker run -d --name itest-unrelated -v /tmp:/w busybox sleep 600 >/dev/null
docker exec -e GITHUB_WORKSPACE="$dir/_work/t" "gha-$name" /opt/gha/hooks/job-started.sh >/dev/null 2>&1
chk "job-started hook empties workspace" '[[ -z "$(ls -A "$dir/_work/t" 2>/dev/null)" ]]'
chk "job-started hook hands root-owned files back" '[[ $(stat -c %u:%g "$dir/_work/_temp/root-file") == 1001:1001 ]]'
chk "job-started hook removes containers left by earlier jobs" '! docker inspect itest-leftover >/dev/null 2>&1'
chk "job-started hook keeps unrelated containers" 'docker inspect itest-unrelated >/dev/null 2>&1'
docker rm -f itest-leftover itest-unrelated >/dev/null 2>&1

section "git checkout cache"
gitenv=(-e GITHUB_REPOSITORY=o/r -e GITHUB_WORKSPACE="$dir/_work/r/r" -e GITHUB_SERVER_URL="file://$dir/_work/_up")
docker exec "gha-$name" bash -c "
  set -e; git config --global user.email t@t; git config --global user.name t
  git init -q --bare $dir/_work/_up/o/r && git init -q /tmp/src && cd /tmp/src && echo 1 >f && git add f && git commit -qm 1
  git push -q file://$dir/_work/_up/o/r HEAD:main
  mkdir -p $dir/_work/r/r && cd $dir/_work/r/r && git init -q && git remote add origin file://$dir/_work/_up/o/r
  git fetch -q --depth=1 origin +main:refs/remotes/origin/main && git checkout -q -B main refs/remotes/origin/main
  printf '#!/bin/sh\ntouch /tmp/hook-ran\n' >.git/hooks/post-checkout && chmod +x .git/hooks/post-checkout
  git config core.hooksPath .git/hooks
  cd /tmp/src && echo 2 >f && git commit -qam 2 && git push -q file://$dir/_work/_up/o/r HEAD:main" >/tmp/git.log 2>&1
docker exec "${gitenv[@]}" "gha-$name" /opt/gha/hooks/job-completed.sh >>/tmp/git.log 2>&1
chk "job-completed stores the repository's .git" '[[ -d $dir/_git/o/r.git/objects && ! -e $dir/_work/r/r/.git ]]'
docker exec "${gitenv[@]}" "gha-$name" /opt/gha/hooks/job-started.sh >>/tmp/git.log 2>&1
chk "job-started puts .git back into the clean workspace" '[[ -d $dir/_work/r/r/.git && ! -e $dir/_git/o/r.git ]]'
docker exec "gha-$name" bash -c "cd $dir/_work/r/r && rm -f /tmp/hook-ran && [[ \$(git config --get remote.origin.url) == file://$dir/_work/_up/o/r ]] \
  && ! git config --get core.hooksPath && git clean -ffdx -q && git reset -q --hard HEAD && [[ \$(cat f) == 1 ]] \
  && git fetch --depth=1 origin +main:refs/remotes/origin/main 2>&1 && git checkout -q -B main refs/remotes/origin/main && [[ \$(cat f) == 2 ]] && [[ ! -e /tmp/hook-ran ]] && echo git-cache-ok" >>/tmp/git.log 2>&1
chk "checkout reuses the restored .git, without old hooks or config" 'grep -q git-cache-ok /tmp/git.log' || tail -20 /tmp/git.log
docker exec -e GHA_GIT_CACHE=0 "${gitenv[@]}" "gha-$name" /opt/gha/hooks/job-completed.sh >/dev/null 2>&1
chk "GHA_GIT_CACHE=0 leaves .git alone" '[[ -d $dir/_work/r/r/.git && ! -e $dir/_git/o/r.git ]]'
docker exec "gha-$name" sudo rm -rf "$dir/_work/r" "$dir/_work/_up" "$dir/_git"

section "disk cleanup (gha-cleanup in the image)"
docker exec "gha-$name" bash -c "mkdir -p $dir/_work/old-repo/old-repo $dir/_work/t/t ~/.cache/pip ~/.npm && touch $dir/_work/old-repo/old-repo/f ~/.cache/pip/f ~/.npm/f /tmp/job-junk"
docker exec -e GITHUB_WORKSPACE="$dir/_work/t/t" "gha-$name" /opt/gha/hooks/job-started.sh >/dev/null 2>&1
chk "other repos' workspaces always removed" '[[ ! -e $dir/_work/old-repo ]]'
chk "below the threshold caches are kept" 'docker exec "gha-$name" test -e /tmp/job-junk'
docker exec "gha-$name" bash -c "mkdir -p $dir/_work/old-repo/old-repo && touch $dir/_work/old-repo/old-repo/f"
chk "job-started marks the runner busy" '[[ -e $dir/.gha-job-running ]]'
docker exec "gha-$name" /usr/local/bin/gha-cleanup --idle >/tmp/cleanup.log 2>&1
chk "idle cleanup skips a busy runner" 'grep -q "job is running" /tmp/cleanup.log && [[ -e $dir/_work/old-repo/old-repo/f ]]'
docker exec "gha-$name" /opt/gha/hooks/job-completed.sh >/dev/null 2>&1
chk "job-completed clears the busy mark" '[[ ! -e $dir/.gha-job-running ]]'
docker exec -e CLEANUP_AT_PERCENT=0 -e GITHUB_WORKSPACE="$dir/_work/t/t" "gha-$name" /opt/gha/hooks/job-started.sh >/tmp/cleanup.log 2>&1
chk "above the threshold: other repos' workspaces removed" '[[ ! -e $dir/_work/old-repo ]]'
chk "above the threshold: the starting job's directory kept" '[[ -d $dir/_work/t/t ]]'
chk "above the threshold: home caches and /tmp emptied" '! docker exec "gha-$name" bash -c "ls ~/.cache/pip ~/.npm /tmp/job-junk" >/dev/null 2>&1'
chk "cleanup reports what it freed" 'grep -q "gha-cleanup: freed" /tmp/cleanup.log'
docker exec "gha-$name" /opt/gha/hooks/job-completed.sh >/dev/null 2>&1

section "disk guard (reserve + cleanup when full)"
chk "disk guard running" 'systemctl is-active --quiet gha-runners-diskguard.service'
for _ in $(seq 1 30); do [[ -s /var/lib/gha-runners/disk-reserve ]] && break; sleep 1; done
chk "disk reserve set aside" '[[ $(stat -c %s /var/lib/gha-runners/disk-reserve 2>/dev/null || echo 0) -ge 536870912 ]]'
systemctl stop gha-runners-diskguard.service
docker exec "gha-$name" bash -c "mkdir -p $dir/_work/old-repo $dir/_work/old-repo2 ~/.cache/x && touch ~/.cache/x/f"
docker pull -q busybox >/dev/null 2>&1
docker volume create buildx_buildkit_itest0_state >/dev/null
docker run -d --name buildx_buildkit_itest0 -v buildx_buildkit_itest0_state:/var/lib/buildkit busybox sleep 600 >/dev/null
echo DISK_FULL_FREE_MB=999999999 >>/etc/gha-runners/config.env
gha-runners _diskguard --once >/tmp/guard.log 2>&1; rc=$?
sed -i '/^DISK_FULL_FREE_MB=/d' /etc/gha-runners/config.env
chk "guard handles a full disk (rc=$rc)" '[[ $rc == 0 ]] && grep -q "disk full" /tmp/guard.log'
chk "full disk: reserve released" '[[ ! -e /var/lib/gha-runners/disk-reserve ]]'
chk "full disk: unused images removed" '! docker image inspect busybox >/dev/null 2>&1'
chk "full disk: leftover buildx builder and its cache removed" '! docker inspect buildx_buildkit_itest0 >/dev/null 2>&1 && ! docker volume inspect buildx_buildkit_itest0_state >/dev/null 2>&1'
chk "full disk: caches dropped" '[[ ! -e /var/lib/gha-runners/package-cache/cache/itest-pkg ]]'
chk "full disk: cache services back up" '(for s in actions mirror apt ghcr quay mcr; do systemctl is-active --quiet gha-runners-cache@$s || exit 1; done)'
chk "full disk: mirror and apt caches dropped" '[[ ! -e /var/lib/gha-runners/ghcr-cache/docker && -z "$(find /var/lib/gha-runners/apt-cache -type f 2>/dev/null)" ]]'
chk "full disk: runner image kept" 'docker image inspect quavon/gha-runner:standard >/dev/null 2>&1'
chk "full disk: idle runner cleaned without Docker too" '[[ ! -e $dir/_work/old-repo2 ]]'
chk "full disk: idle runner cleaned by gha-cleanup" '[[ ! -e $dir/_work/old-repo ]] && grep -q "$name: gha-cleanup: freed" /tmp/guard.log'
gha-runners _diskguard --once >/tmp/guard.log 2>&1
chk "reserve set aside again once there is room" '[[ -s /var/lib/gha-runners/disk-reserve ]]'
systemctl start gha-runners-diskguard.service

section "CLI"
gha-runners list >/tmp/list.log 2>&1
chk "gha-runners list shows runner" 'grep -q "$name" /tmp/list.log'
gha-runners limits --cpus 1 --memory 1024 >/dev/null 2>&1
sleep 6
chk "limits change applied after restart" 'docker inspect gha-$name 2>/dev/null | grep -q "\"Memory\": 1073741824"'
chk "parallelism hints follow the new cap" 'docker inspect gha-$name 2>/dev/null | grep -q "\"GOMAXPROCS=1\""'
gha-runners limits --cpus 999 >/dev/null 2>&1
sleep 6
chk "cpu cap above the LXC's cores is clamped" 'docker inspect gha-$name 2>/dev/null | grep -q "\"NanoCpus\": $(nproc)000000000"'
gha-runners doctor >/tmp/doctor.log 2>&1; rc=$?
chk "doctor reads the runner's cgroup (rc=$rc)" '[[ $rc == 0 ]] && grep -q "storage driver" /tmp/doctor.log && grep -qE "^$name +[0-9]+%" /tmp/doctor.log'
chk "doctor shows every cache" '(for s in actions mirror apt ghcr quay mcr; do grep -qE "^$s cache +: active" /tmp/doctor.log || exit 1; done)'
gha-runners stop "$name" >/dev/null 2>&1
docker tag quavon/gha-runner:standard quavon/gha-runner:full
printf 'FROM busybox\nLABEL com.quavon.gha-runner=true\nLABEL v=1\n' | docker build -q -t quavon/gha-runner:replaced - >/dev/null 2>&1
printf 'FROM busybox\nLABEL com.quavon.gha-runner=true\nLABEL v=2\n' | docker build -q -t quavon/gha-runner:replaced - >/dev/null 2>&1
old_runner_images="$(docker images -q --filter dangling=true --filter label=com.quavon.gha-runner | wc -l)"
gha-runners prune >/tmp/prune.log 2>&1
chk "prune removes runner images an update replaced, at once" '(( old_runner_images > 0 )) && [[ -z "$(docker images -q --filter dangling=true --filter label=com.quavon.gha-runner)" ]]'
docker image rm quavon/gha-runner:replaced >/dev/null 2>&1
docker run -d --name itest-forgotten-cluster busybox sleep 3600 >/dev/null
docker run -d --name itest-kept --label com.quavon.keep=true busybox sleep 3600 >/dev/null
docker run -d --name gha-itest-sidecar busybox sleep 3600 >/dev/null
sleep 61
docker run -d --name itest-young busybox sleep 3600 >/dev/null
echo LEFTOVER_MINUTES=1 >>/etc/gha-runners/config.env
gha-runners prune >/tmp/leftover.log 2>&1
sed -i '/^LEFTOVER_MINUTES=/d' /etc/gha-runners/config.env
chk "prune removes containers jobs left running too long" '! docker inspect itest-forgotten-cluster >/dev/null 2>&1 && grep -q "removing itest-forgotten-cluster: left running by a job" /tmp/leftover.log'
chk "prune keeps young, labelled and gha-* containers" 'docker inspect itest-young itest-kept gha-itest-sidecar >/dev/null 2>&1'
docker rm -f itest-young itest-kept gha-itest-sidecar >/dev/null 2>&1
gha-runners prune --all >/tmp/prune.log 2>&1; rc=$?
chk "prune --all succeeds (rc=$rc)" '[[ $rc == 0 ]]'
chk "prune keeps the runner image with runners stopped" 'docker image inspect quavon/gha-runner:standard >/dev/null 2>&1'
chk "prune drops unused job images" '! docker image inspect busybox >/dev/null 2>&1'
chk "prune drops runner images of other flavors" '! docker image inspect quavon/gha-runner:full >/dev/null 2>&1'

section "update moves runners from name directories to slots"
for n in itest-old itest-busy; do
  cp -a "$dir" "/srv/gha-runners/$n"
  rm -rf "/srv/gha-runners/$n/_work" "/srv/gha-runners/$n/_diag" "/srv/gha-runners/$n"/.credentials*
  sed -e "s/^RUNNER_NAME=.*/RUNNER_NAME=$n/" -e "s|^RUNNER_DIR=.*|RUNNER_DIR=/srv/gha-runners/$n|" "/etc/gha-runners/runners/$name.env" >"/etc/gha-runners/runners/$n.env"
  chmod 600 "/etc/gha-runners/runners/$n.env"
  systemctl start "gha-runner@$n"
done
listening() {   # past the entrypoint, which clears the job mark
  for _ in $(seq 1 60); do docker top "$1" 2>/dev/null | grep -qE 'run(-helper)?\.sh|Runner\.Listener' && return 0; sleep 1; done
  return 1
}
mark_busy() { listening gha-itest-busy; touch /srv/gha-runners/itest-busy/.gha-job-running; }
mark_busy
gha-runners _update_image </dev/null >/tmp/update-image.log 2>&1; rc=$?
chk "update rebuilds in place on the classic store (rc=$rc)" '[[ $rc == 0 ]] && ! grep -q "switching to the classic" /tmp/update-image.log && grep -q "restart: all" /tmp/update-image.log'
new=/srv/gha-runners/r2
chk "an idle runner is moved to the lowest free slot" '[[ ! -e /srv/gha-runners/itest-old && -x $new/run.sh ]] && grep -qx "RUNNER_DIR=$new" /etc/gha-runners/runners/itest-old.env && grep -q "itest-old. moved from /srv/gha-runners/itest-old to $new" /tmp/update-image.log'
chk "a runner in a job keeps its directory" '[[ -d /srv/gha-runners/itest-busy ]] && grep -qx "RUNNER_DIR=/srv/gha-runners/itest-busy" /etc/gha-runners/runners/itest-busy.env && grep -q "itest-busy. is running a job" /tmp/update-image.log'
listening gha-itest-old
chk "the moved runner starts with the new same-path mount" 'systemctl is-active --quiet gha-runner@itest-old && docker inspect gha-itest-old | grep -q "\"$new:$new\"" && ! docker inspect gha-itest-old | grep -q /srv/gha-runners/itest-old'
chk "nothing in the moved runner refers to the old directory" '[[ -z "$(grep -rlF /srv/gha-runners/itest-old "$new" --exclude-dir=_diag)" ]]'
docker exec gha-itest-old bash -c "mkdir -p $new/_work/t && echo hello >$new/_work/t/f && docker run --rm -v $new/_work/t:/w busybox cat /w/f" >/tmp/samepath.log 2>&1
chk "container jobs of the moved runner see its workspace" 'grep -qx hello /tmp/samepath.log'
mark_busy
(source <(sed '$d' /usr/local/bin/gha-runners); migrate_runner_dirs) >/tmp/migrate-again.log 2>&1
chk "a second update moves nothing" '! grep -q moved /tmp/migrate-again.log && grep -qx "RUNNER_DIR=$new" /etc/gha-runners/runners/itest-old.env && systemctl is-active --quiet gha-runner@itest-old'
gha-runners remove itest-old </dev/null >/dev/null 2>&1
gha-runners remove itest-busy </dev/null >/dev/null 2>&1
chk "remove frees the slot" '[[ ! -e $new && ! -e /srv/gha-runners/itest-busy ]] && [[ $(source <(sed "\$d" /usr/local/bin/gha-runners); free_slot_dir) == $new ]]'
gha-runners migrate-storage </dev/null >/tmp/migrate.log 2>&1; rc=$?
chk "migrate-storage is a no-op on the classic store (rc=$rc)" '[[ $rc == 0 ]] && grep -q "already uses the classic" /tmp/migrate.log'
chk "hourly prune service runs" 'systemctl start gha-runners-prune.service'
if [[ -z "${GH_TEST_TOKEN:-}" ]]; then
  gha-runners remove "$name" </dev/null >/tmp/remove.log 2>&1
  chk "remove cleans up locally" '[[ ! -e $dir && ! -e /etc/gha-runners/runners/$name.env ]] && ! docker inspect gha-$name >/dev/null 2>&1'
fi

printf '\nlxc integration: %s passed, %s failed\n' "$pass" "$fail"
exit $(( fail > 0 ))
