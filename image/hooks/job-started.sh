#!/usr/bin/env bash
# Runs before every job. Persistent runners keep state between jobs, so give
# each job a clean, runner-owned workspace like a fresh hosted VM would have.
set -uo pipefail

[[ -n "${RUNNER_DIR:-}" ]] || exit 0
work="${RUNNER_DIR}/_work"

# Default workspace layout is _work/<repo>/<repo>; use it if the hook env lacks GITHUB_WORKSPACE.
workspace="${GITHUB_WORKSPACE:-}"
if [[ -z "$workspace" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  repo="${GITHUB_REPOSITORY#*/}"
  workspace="${work}/${repo}/${repo}"
fi
workspace="${workspace%/}"

# Mark the runner busy so the LXC's disk guard leaves it alone until
# job-completed. The lock waits for a guard cleanup that is already running.
exec 9>"${RUNNER_DIR}/.gha-cleanup.lock"
flock -w 600 9 || true
touch "${RUNNER_DIR}/.gha-job-running"

# Leftover containers of earlier jobs; above 80% disk also images, caches and
# other repositories' workspaces. Keeps this job's directory.
keep=""
[[ "$workspace" == "$work"/*/* ]] && keep="${workspace%/*}"
/usr/local/bin/gha-cleanup --keep "$keep"
exec 9>&-

if [[ "${RUNNER_EPHEMERAL:-0}" != 1 && -d "$work" ]]; then
  # Container jobs write files as root; fix ownership so checkout never fails.
  sudo find "$work" \( ! -user runner -o ! -group runner \) -exec chown -h runner:runner {} + 2>/dev/null || true

  if [[ -n "$workspace" && -d "$workspace" && "$workspace" == "$work"/* ]]; then
    echo "Cleaning workspace ${workspace}"
    sudo find "$workspace" -mindepth 1 -delete 2>/dev/null || true
  fi
fi
/usr/local/bin/gha-git-cache restore
# Swatinem/rust-cache deletes the toolchain binaries from CARGO_HOME/bin after a job.
[[ -d /opt/gha/cargo-bin ]] && cp -an /opt/gha/cargo-bin/. /usr/share/rust/.cargo/bin/ 2>/dev/null
exit 0
