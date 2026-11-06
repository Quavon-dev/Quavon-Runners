#!/usr/bin/env bash
# flavors: full full-plus
# Cloud CLIs: AWS CLI v2, Azure CLI, Google Cloud CLI; plus ansible and kind.
source "$(dirname "$0")/lib.sh"
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
AWS_CLI_FPR=FB5DB77FD5C118B80511ADA8A6310ACC4672475C

log "AWS CLI v2"
aws_arch=x86_64; is_amd64 || aws_arch=aarch64
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o /tmp/awscli.zip
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip.sig" -o /tmp/awscli.zip.sig
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${AWS_CLI_FPR}" | gpg -q --import
[[ "$(gpg --status-fd 1 --verify /tmp/awscli.zip.sig /tmp/awscli.zip 2>/dev/null)" == *"[GNUPG:] VALIDSIG ${AWS_CLI_FPR} "* ]] \
  || die "signature check failed: AWS CLI"
unzip -q /tmp/awscli.zip -d /tmp
/tmp/aws/install

log "Azure CLI"
add_apt_repo azure-cli https://packages.microsoft.com/keys/microsoft.asc \
  "https://packages.microsoft.com/repos/azure-cli/ ${codename} main"
apt_install azure-cli

log "Google Cloud CLI"
add_apt_repo google-cloud https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  "https://packages.cloud.google.com/apt cloud-sdk main"
apt_install google-cloud-cli

log "ansible (pipx)"
PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/opt/pipx_bin pipx install --include-deps ansible
chown -R runner:runner /opt/pipx /opt/pipx_bin

log "kind"
kind_tag="$(gh_latest_tag kubernetes-sigs/kind)"
kind_url="https://github.com/kubernetes-sigs/kind/releases/download/${kind_tag}/kind-linux-$(arch_deb)"
install -m 0755 "$(fetch "$kind_url" "$(sha_of "${kind_url}.sha256sum")")" /usr/local/bin/kind
