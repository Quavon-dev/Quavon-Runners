#!/usr/bin/env bash
# Unit tests for install.sh / gha-runners helpers. Run via tests/run.sh.
# shellcheck disable=SC2034,SC2329  # globals/stubs are consumed by the sourced code
set -uo pipefail
ROOT="${ROOT:-/src}"
fail=0 pass=0
t() { if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
ok() { if eval "$2"; then pass=$((pass + 1)); else echo "FAIL $1"; fail=1; fi; }

# ---- install.sh helpers (sourced without running main)
sed '$d' "$ROOT/install.sh" >/tmp/install-lib.sh
# shellcheck source=/dev/null
source /tmp/install-lib.sh
trap - EXIT ERR INT TERM HUP
set +e

t "labels: spaces + builtin"   "$(normalize_labels 'docker, linux')" "docker"
t "labels: dedupe + case"      "$(normalize_labels ' docker, GPU ,docker,,self-hosted,X64,gpu')" "docker,GPU"
t "labels: empty"              "$(normalize_labels '')" ""
ok "labels: valid"             'valid_labels "docker,gpu-1,a.b_c"'
ok "labels: invalid rejected"  '! valid_labels "bad label!"'
t "csv normalize"              "$(normalize_csv ' 10.0.0.5, 10.0.1.0/24 ,')" "10.0.0.5,10.0.1.0/24"
t "trim"                       "$(normalize_trim '  ab c  ')" "ab c"
ok "count 1..32"               'valid_count 1 && valid_count 32 && ! valid_count 0 && ! valid_count 33 && ! valid_count abc && ! valid_count 07'
ok "ipv4"                      'valid_ipv4 192.168.1.1 && ! valid_ipv4 256.1.1.1 && ! valid_ipv4 1.2.3'
ok "net ip"                    'valid_net_ip dhcp && valid_net_ip 10.0.0.5/24 && ! valid_net_ip 10.0.0.5 && ! valid_net_ip 10.0.0.5/33'
ok "vlan"                      'valid_vlan "" && valid_vlan 4094 && ! valid_vlan 4095 && ! valid_vlan x'
ok "lan allow"                 'valid_lan_allow "" && valid_lan_allow "10.0.0.5,192.168.50.0/24" && ! valid_lan_allow "10.0.0.5;rm"'
NET_ISOLATION=internet
ok "dns public only"           'valid_dns "1.1.1.1 9.9.9.9" && ! valid_dns "192.168.1.1" && ! valid_dns ""'
NET_ISOLATION=lan
ok "dns lan allowed in lan mode" 'valid_dns "192.168.1.1"'
ok "name"                      'valid_name gha-runners && ! valid_name -x && ! valid_name "a b"'
ok "url"                       'valid_url https://github.com/a/b && valid_url https://github.com/enterprises/x && ! valid_url https://github.com/a/b/c && ! valid_url http://github.com/a'
ok "token"                     'valid_token AAAABBBBCCCCDDDDEEEE && ! valid_token "x;rm -rf"'
t "paste parse"                "$(parse_pair_input './config.sh --url https://github.com/o/r/ --token ABCDEFGHIJKLMNOPQRST')" "https://github.com/o/r ABCDEFGHIJKLMNOPQRST"
t "ip offset"                  "$(ip_offset 192.168.1.50/24 2)" "192.168.1.52/24"
ok "private ip"                'is_private_ip 10.1.2.3 && is_private_ip 172.20.0.1 && is_private_ip 100.64.0.1 && ! is_private_ip 1.1.1.1 && ! is_private_ip 172.32.0.1'

# sizing
RUNNER_FLAVOR=standard RUNNER_COUNT=2 LAYOUT=shared RUNNER_CPUS=2 RUNNER_MEM=4096
host_cpus() { echo 8; }
unset CORES RAM SWAP DISK; size_defaults 6
t "size shared 2x medium"      "$CORES $RAM $DISK" "4 9216 22"
RUNNER_COUNT=3 LAYOUT=separate; unset CORES RAM SWAP DISK; size_defaults 6
t "size separate per CT"       "$CORES $RAM $DISK" "2 5120 14"
RUNNER_COUNT=8 LAYOUT=shared RUNNER_CPUS=4; unset CORES RAM SWAP DISK; size_defaults 10
t "cpu leaves a host core"     "$CORES" "7"
host_cpus() { echo 1; }; unset CORES RAM SWAP DISK; size_defaults 10
t "cpu on a 1-core host"       "$CORES" "1"
host_cpus() { echo 8; }
RUNNER_FLAVOR=full-plus RUNNER_COUNT=2 RUNNER_CPUS=2; unset CORES RAM SWAP DISK; size_defaults 6
t "size full-plus image"       "$DISK" "35"
RUNNER_FLAVOR=standard

# firewall rules
mkdir -p /etc/pve/firewall; CTID=150 LAN_ALLOW="10.0.0.5"
hostname() { echo "203.0.113.7"; }
write_ct_firewall
fw="$(cat /etc/pve/firewall/150.fw)"
ok "fw inbound drop"           '[[ "$fw" == *"policy_in: DROP"* ]]'
ok "fw ipv6 blocked"           '[[ "$fw" == *"::/1"* && "$fw" == *"8000::/1"* && "$fw" != *"::/0"* ]]'
ok "fw host ip blocked"        '[[ "$fw" == *"203.0.113.7"* ]]'
ok "fw exception first"        '[[ "$fw" == *$'"'"'OUT ACCEPT -dest +lan_allow -log nolog\nOUT REJECT'"'"'* ]]'
unset -f hostname

# ---- gha-runners CLI helpers
sed '$d' "$ROOT/lxc/gha-runners" >/tmp/ghr-lib.sh
# shellcheck source=/dev/null
source /tmp/ghr-lib.sh
set +e
t "cli api repo"  "$(token_api https://github.com/o/r registration)" "https://api.github.com/repos/o/r/actions/runners/registration-token"
t "cli api org"   "$(token_api https://github.com/o remove)" "https://api.github.com/orgs/o/actions/runners/remove-token"
t "cli api ent"   "$(token_api https://github.com/enterprises/e registration)" "https://api.github.com/enterprises/e/actions/runners/registration-token"
t "cli api ghes"  "$(token_api https://ghe.corp/t/r registration)" "https://ghe.corp/api/v3/repos/t/r/actions/runners/registration-token"

# disk reserve: 10% of the disk, at least 512 MB, at most 10 GB, 0 = off
disk_size_mb() { echo 20000; }
t "reserve 10%"        "$(reserve_target_mb)" "2000"
disk_size_mb() { echo 2000; }
t "reserve minimum"    "$(reserve_target_mb)" "512"
disk_size_mb() { echo 500000; }
t "reserve maximum"    "$(reserve_target_mb)" "10240"
t "reserve off"        "$(DISK_RESERVE_PERCENT=0 reserve_target_mb)" "0"
t "reserve bad value"  "$(DISK_RESERVE_PERCENT=abc reserve_target_mb)" "0"
unset -f disk_size_mb
ok() { if eval "$2"; then pass=$((pass + 1)); else echo "FAIL $1"; fail=1; fi; }

t "image size full-plus" "$(image_gb full-plus)" "15"
t "image size standard"  "$(image_gb standard)" "3"
ok "caches on by default" '(for s in $CACHE_SERVICES; do cache_enabled "$s" || exit 1; done)'
ok "caches switch off"   '! LOCAL_ACTIONS_CACHE=0 cache_enabled actions && ! DOCKER_HUB_MIRROR=0 cache_enabled mirror && ! APT_PROXY=0 cache_enabled apt && ! GHCR_MIRROR=0 cache_enabled ghcr && ! QUAY_MIRROR=0 cache_enabled quay && ! MCR_MIRROR=0 cache_enabled mcr'
ok "every cache has its own port" '[[ $(for s in $CACHE_SERVICES; do cache_port "$s"; done | sort -u | wc -l) == $(wc -w <<<"$CACHE_SERVICES") ]]'

# prebuilt image: only for a clean image/ tree of a git checkout
repo="$(mktemp -d)"; mkdir -p "$repo/image"; echo a >"$repo/image/f"
git -C "$repo" init -q && git -C "$repo" add . && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm i
docker() { echo "docker $*" >>/tmp/docker-calls; [[ "$*" != "pull --platform linux/amd64 172.17.0.1:29174/"*"$mirror_fails" ]]; }
info() { :; }
dpkg() { echo amd64; }
bridge_ip() { echo 172.17.0.1; }
tree="$(git -C "$repo" rev-parse HEAD:image)" mirror_fails=never
: >/tmp/docker-calls
REPO_DIR="$repo" pull_image full quavon/gha-runner:full
ok "prebuilt pulled by tree hash through the ghcr mirror" 'grep -qx "docker pull --platform linux/amd64 172.17.0.1:29174/quavon-dev/gha-runner:full-$tree" /tmp/docker-calls && ! grep -q "pull .* ghcr.io" /tmp/docker-calls'
ok "prebuilt retagged locally" 'grep -qx "docker tag 172.17.0.1:29174/quavon-dev/gha-runner:full-$tree ghcr.io/quavon-dev/gha-runner:full-$tree" /tmp/docker-calls && grep -q "docker tag ghcr.io/quavon-dev/gha-runner:full-.* quavon/gha-runner:full" /tmp/docker-calls'
mirror_fails="" ; : >/tmp/docker-calls
REPO_DIR="$repo" pull_image full quavon/gha-runner:full
ok "mirror fails: pulled from GHCR directly" 'grep -qx "docker pull --platform linux/amd64 ghcr.io/quavon-dev/gha-runner:full-$tree" /tmp/docker-calls'
mirror_fails=never; : >/tmp/docker-calls
GHCR_MIRROR=0 REPO_DIR="$repo" pull_image full quavon/gha-runner:full
ok "GHCR_MIRROR=0 pulls from GHCR directly" '! grep -q 29174 /tmp/docker-calls && grep -qx "docker pull --platform linux/amd64 ghcr.io/quavon-dev/gha-runner:full-$tree" /tmp/docker-calls'
echo b >"$repo/image/f"; : >/tmp/docker-calls
ok "local changes build locally" '! REPO_DIR="$repo" pull_image full quavon/gha-runner:full && [[ ! -s /tmp/docker-calls ]]'
ok "PREBUILT_IMAGE= turns pulling off" '! PREBUILT_IMAGE= REPO_DIR="$repo" pull_image full x'
ok "no git checkout builds locally" '! REPO_DIR=/tmp pull_image full x'
dpkg() { echo arm64; }; : >/tmp/docker-calls
ok "other architectures build locally" '! REPO_DIR="$repo" pull_image full x && [[ ! -s /tmp/docker-calls ]]'
unset -f docker info dpkg bridge_ip
rm -rf "$repo"

# runner patch: ACTIONS_RESULTS_URL (UTF-16) renamed so the runner keeps ours
dir="$(mktemp -d)"; mkdir -p "$dir/bin"
printf 'xx\x00A\x00C\x00T\x00I\x00O\x00N\x00S\x00_\x00R\x00E\x00S\x00U\x00L\x00T\x00S\x00_\x00U\x00R\x00L\x00yy' >"$dir/bin/Runner.Worker.dll"
utf16() { printf %s "$1" | sed 's/./&\\x00/g'; }
RUNNER_DIR="$dir" bash "$ROOT/image/tools/gha-patch-runner"
ok "runner patch without cache URL: untouched" 'LC_ALL=C grep -qaP "$(utf16 ACTIONS_RESULTS_URL)" "$dir/bin/Runner.Worker.dll"'
RUNNER_DIR="$dir" ACTIONS_RESULTS_URL=http://172.17.0.1:29171/ bash "$ROOT/image/tools/gha-patch-runner"
ok "runner patch renames the variable" 'LC_ALL=C grep -qaP "$(utf16 ACTIONS_RESULTS_ORL)" "$dir/bin/Runner.Worker.dll" && ! LC_ALL=C grep -qaP "$(utf16 ACTIONS_RESULTS_URL)" "$dir/bin/Runner.Worker.dll"'
t "runner patch keeps the size" "$(stat -c %s "$dir/bin/Runner.Worker.dll")" "43"
rm -rf "$dir"

echo "unit: ${pass} passed$([[ $fail == 1 ]] && echo ', FAILURES above')"
exit "$fail"
