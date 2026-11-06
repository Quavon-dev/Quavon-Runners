# Contributing

Thanks for helping out. Bug reports, fixes and features are welcome.

## Before you start

- For larger changes, open an issue first so we can agree on the approach.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Running the tests

Everything runs in Docker on any machine; no Proxmox host is needed.

```bash
tests/run.sh               # shellcheck + unit tests + end-to-end installer runs (~5 min)
tests/run.sh e2e NAME      # a single end-to-end case, e.g. tests/run.sh e2e happy_shared
tests/lxc/run.sh           # LXC integration: real Docker, systemd units, image build (~20 min, privileged Docker)
```

`tests/run.sh` needs `shellcheck` on the host. CI also runs
[actionlint](https://github.com/rhysd/actionlint),
[hadolint](https://github.com/hadolint/hadolint),
[zizmor](https://github.com/zizmorcore/zizmor) and
[gitleaks](https://github.com/gitleaks/gitleaks); running them locally before
you push saves a round trip:

```bash
actionlint
hadolint image/Dockerfile tests/lxc/Dockerfile
zizmor .github
gitleaks git .
```

The LXC integration test runs in CI only on demand (**Actions → ci → Run workflow**, with `lxc` checked).
Run it locally when you change `lxc/`, the systemd units or the image.

## Style

- Match the existing code: bash with `set -euo pipefail`, two-space indent, small
  functions, the same naming and idioms as the surrounding file.
- No comments unless the code cannot explain itself.
- Keep changes focused. Avoid unrelated refactors, new dependencies and new files
  you don't need.
- Pin GitHub Actions by full commit SHA with the version as a trailing comment,
  give every job least-privilege `permissions:`, and use `persist-credentials: false`
  on checkout.
- Never commit secrets, tokens or real credentials, including in tests and examples.
- Add or update tests for behaviour changes, and update the docs (README.md or docs/) when user-facing
  behaviour changes.

## Pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/) style messages
  (`fix: ...`, `feat: ...`, `chore: ...`).
- Fill in the pull request template and make sure CI is green.
