#!/usr/bin/env bash
# flavors: full full-plus
# Latest stable Go.
source "$(dirname "$0")/lib.sh"

version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
log "Go ${version}"
file="${version}.linux-$(arch_deb).tar.gz"
sha="$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r --arg f "$file" '.[].files[] | select(.filename == $f) | .sha256')"
tar -xzf "$(fetch "https://go.dev/dl/${file}" "$sha")" -C /usr/local
add_path /usr/local/go/bin
add_path /home/runner/go/bin
