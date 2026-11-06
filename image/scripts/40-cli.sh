#!/usr/bin/env bash
# flavors: standard full full-plus
# Common CLIs: yq, kubectl, helm.
source "$(dirname "$0")/lib.sh"

log "yq"
yq_base="https://github.com/mikefarah/yq/releases/download/$(gh_latest_tag mikefarah/yq)"
yq_col="$(curl -fsSL "${yq_base}/checksums_hashes_order" | grep -nx SHA-256 | cut -d: -f1)"
yq_sha="$(curl -fsSL "${yq_base}/checksums" | awk -v f="yq_linux_$(arch_deb)" -v c="$((yq_col + 1))" '$1 == f {print $c}')"
install -m 0755 "$(fetch "${yq_base}/yq_linux_$(arch_deb)" "$yq_sha")" /usr/local/bin/yq

log "kubectl"
k8s_minor="$(curl -fsSL https://dl.k8s.io/release/stable.txt | cut -d. -f1,2)"
add_apt_repo kubernetes "https://pkgs.k8s.io/core:/stable:/${k8s_minor}/deb/Release.key" \
  "https://pkgs.k8s.io/core:/stable:/${k8s_minor}/deb/ /"
apt_install kubectl

log "helm"
helm_url="https://get.helm.sh/helm-$(curl -fsSL https://get.helm.sh/helm3-latest-version)-linux-$(arch_deb).tar.gz"
tar -xzf "$(fetch "$helm_url" "$(sha_of "${helm_url}.sha256sum")")" -C /tmp "linux-$(arch_deb)/helm"
install -m 0755 "/tmp/linux-$(arch_deb)/helm" /usr/local/bin/helm
