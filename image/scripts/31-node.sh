#!/usr/bin/env bash
# flavors: standard full full-plus
# Node.js LTS (NodeSource) + npm; yarn and pnpm through Corepack.
source "$(dirname "$0")/lib.sh"

NODE_MAJOR="${NODE_MAJOR:-22}"

log "Node.js ${NODE_MAJOR}"
add_apt_repo nodesource https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  "https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main"
apt_install nodejs
corepack enable yarn pnpm
add_env COREPACK_ENABLE_DOWNLOAD_PROMPT 0
