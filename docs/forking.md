# Forking

Install from your fork by pointing `install.sh` at it:

```bash
REPO_URL=https://github.com/<you>/Quavon-Runners.git REPO_BRANCH=main \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/<you>/Quavon-Runners/main/install.sh)"
```

Runner images come from `PREBUILT_IMAGE` in `/etc/gha-runners/config.env` inside the LXC (default `ghcr.io/quavon-dev/gha-runner`). A prebuilt image is only used when its tag matches the git tree hash of your `image/` directory, so a modified `image/` is built locally anyway.

- `PREBUILT_IMAGE=` (empty) always builds locally.
- `PREBUILT_IMAGE=ghcr.io/<you>/gha-runner` pulls your own images.

`.github/workflows/image.yml` publishes to the GHCR of the repository owner, so a fork publishes `ghcr.io/<you>/gha-runner:<flavor>-<tree hash>` with build provenance attestations without changes. Make the package public, or log the LXC in to GHCR, before pulling from it.

`RUNNER_VERSION=2.330.0` in the same file pins the actions/runner release downloaded for new runners (default: latest). The download is checked against the SHA-256 published with the release.
