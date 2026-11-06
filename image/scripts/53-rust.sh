#!/usr/bin/env bash
# flavors: full full-plus
# Rust stable via rustup, owned by the runner user so jobs can add targets.
source "$(dirname "$0")/lib.sh"

log "Rust"
export RUSTUP_HOME=/usr/share/rust/.rustup CARGO_HOME=/usr/share/rust/.cargo
install -d -o runner -g runner /usr/share/rust
rustup_url="https://static.rust-lang.org/rustup/dist/$(uname -m)-unknown-linux-gnu/rustup-init"
rustup_init="$(fetch "$rustup_url" "$(sha_of "${rustup_url}.sha256")")"
chmod 0755 "$rustup_init"
as_runner env RUSTUP_HOME="$RUSTUP_HOME" CARGO_HOME="$CARGO_HOME" \
  "$rustup_init" -y --profile minimal --component rustfmt,clippy --no-modify-path
add_env RUSTUP_HOME "$RUSTUP_HOME"
add_env CARGO_HOME "$CARGO_HOME"
add_path "$CARGO_HOME/bin"
