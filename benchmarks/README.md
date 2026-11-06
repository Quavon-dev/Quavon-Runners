# Benchmark: GitHub-hosted vs. self-hosted runners

Real open-source builds on GitHub's `ubuntu-latest` and on runners installed with this repository.
Two rounds on 2026-11-06: round 1 in the afternoon, round 2 in the evening, after the cache fixes
listed below were installed on all LXCs. Raw numbers:
[`results/2026-11-06-r2.json`](results/2026-11-06-r2.json) (round 2),
[`results/2026-11-06.json`](results/2026-11-06.json) (round 1), summary of both:
[`summary.json`](summary.json).

**Short version (round 2):** with all four runners of one host busy at once, self-hosted was
level on Node, 18% faster on Docker, and still slower on Go (1.6×) and Rust (2.3×), because
their build caches only help on the runner that saved them and four jobs share a 6-core
desktop CPU. With one job at a time, self-hosted was faster on every workload (5–34%), but the
Go and Rust jobs happened to land on runners that had built them before. Compared with
round 1, the self-hosted side got faster in every warm and serial measurement.

## Results (round 2)

Total job time in seconds (job start to job end, queue time excluded). Warm: median of 3 runs
(min–max). Speedup = hosted / self-hosted, above 1 means self-hosted is faster.

| Workload | Hosted cold | Self-hosted cold | Hosted warm | Self-hosted warm | Speedup warm |
|---|---:|---:|---:|---:|---:|
| Node: axios install, build, unit tests | 115 | 137 | 125 (122–127) | 126 (121–134) | 0.99 |
| Go: caddy build, tests | 207 | 245 | 65 (60–71) | 106 (85–117) | 0.61 |
| Rust: ripgrep release build | 81 | 120 | 35 (35–37) | 79 (50–98) | 0.44 |
| Docker: distribution image, `type=gha` cache | 180 | 176 | 162 (141–162) | 137 (127–141) | 1.18 |

Warm, one job at a time (`max_parallel=1`, 2 runs, median (both runs)):

| Workload | Hosted | Self-hosted | Speedup |
|---|---:|---:|---:|
| Node | 120 (119, 121) | 114.5 (116, 113) | 1.05 |
| Go | 66.5 (72, 61) | 49.5 (52, 47) | 1.34 |
| Rust | 41.5 (38, 45) | 31 (31, 31) | 1.34 |
| Docker | 128 (119, 137) | 105 (107, 103) | 1.22 |

Both serial Go jobs ran on `docker-runners-1-4`, which had built caddy in warm 2, and both
serial Rust jobs on `docker-runners-1-3`, which had saved the Rust cache in the cold round.
On a runner that hasn't built the project yet, Go and Rust would have looked like the slower
parallel runs (see [What still costs time](#what-still-costs-time)).

Queue time was 1–3 s on both sides in every round.

### Round 2 vs. round 1 (medians, seconds)

| Workload | Round | Hosted cold | Self-hosted cold | Hosted warm | Self-hosted warm | Hosted serial | Self-hosted serial |
|---|---|---:|---:|---:|---:|---:|---:|
| Node | 2 | 115 | 137 | 125 | **126** | 120 | **114.5** |
| | 1 | 121 | 145 | 126 | 147 | 113 | 140 |
| Go | 2 | 207 | 245 | 65 | **106** | 66.5 | **49.5** |
| | 1 | 241 | 293 | 66 | 132 | 63 | 94 |
| Rust | 2 | 81 | 120 | 35 | **79** | 41.5 | **31** |
| | 1 | 81 | 92 | 36 | 112 | 40 | failed |
| Docker | 2 | 180 | 176 | 162 | **137** | 128 | **105** |
| | 1 | 167 | 232 | 148 | 160 | 148.5 | 114.5 |

The hosted side moved by up to 15% between the rounds with nothing changed on it, which is
the noise level of this setup. The Rust cold run was slower in round 2 (120 s vs. 92 s):
the build took 85 s instead of 53 s while the Go cold build ran next to it; one cold run
per round can't separate that from noise.

### Where the time goes (round 2, warm in parallel, medians, seconds)

| Step | Hosted | Self-hosted | Round 1 self-hosted |
|---|---:|---:|---:|
| Node: `setup-node` (Node 22.21.0, npm cache) | 9 | 1 | 18 |
| Node: `npm ci` | 4 | 7 | 6 |
| Node: unit tests (CPU bound) | 89 | 91 | 93 |
| Go: `setup-go` (Go, restore 500 MB cache) | 24 | 23 | 37 |
| Go: `go build ./...` | 4 | 26 (8, 26, 41) | 26 |
| Go: tests (CPU bound) | 22 | 42 | 41 |
| Go: post `setup-go` (cache save) | 0 | 0 | 11 |
| Rust: `rustup toolchain install` | 7 | 11 (0 on a runner that has it) | 17 |
| Rust: `cargo build --release` | 17 | 50 (32, 50, 67) | 80 |
| Docker: `setup-buildx` | 7 | 4 | 3 |
| Docker: build | 139 | 109 | 135 |
| Checkout of the own repository (full history, 10 MB) | 2 | 1 | 1 |

With one job at a time, Go's tests took 20–21 s on the self-hosted runner and 20–26 s
hosted: the CPU-bound steps are level when the host isn't shared, and about 2× slower with
four jobs on it.

## What the logs show

Checked in every self-hosted job log of round 2:

- **`setup-go` cache restore works.** Every warm Go job: `Cache restored successfully`,
  499 MB, `Cache hit occurred on the primary key ..., not saving cache`. In round 1 the
  restore failed on read-only module files and the cache was uploaded again each time (11 s).
- **Shared tool cache works.** Node 22.21.0 and Go 1.26.0 were downloaded once, in the cold
  round (`Attempting to download`). Every later job logged `Found in cache @
  /opt/hostedtoolcache/...`, including runners that had never run that workload in this round
  (`docker-runners-1-4` for Node, `1-3` and `1-4` for Go). `setup-node` dropped from 18 s to 1 s.
- **Docker images come through the mirror.** `docker info` lists the mirror
  `http://172.17.0.1:29172/`, and the builder created by `docker/setup-buildx-action` gets the
  generated `buildkitd.toml` with `docker.io`, `ghcr.io`, `quay.io` and `mcr.microsoft.com`
  pointed at `172.17.0.1:29172`, `:29174`, `:29175`, `:29176`. The `golang:1.26.8-alpine3.24`
  layer (67 MB) took 4.1 s in the cold round, at Docker Hub speed (the mirror on the new
  shared cache had not seen it yet), and 0.3–0.6 s in every warm round, in a new builder each
  time; GitHub-hosted took 0.5 s and 6.1 s for it in the two runs checked. `moby/buildkit` was already on every runner
  (`Image is up to date`), so `setup-buildx` took 3 s in the cold round (round 1: 25 s, it
  pulled the image first).
- **Git checkout cache works.** `.git` was present before checkout in every self-hosted job
  (`git_cache: true` in the probe), the cold round included.
- **Rust toolchain stays installed.** No job failed with `rustup: command not found`, unlike
  both serial rounds of round 1 (`cache-bin: false` and the restore after `rust-cache`).
- **apt:** no step of this benchmark uses apt, so the apt proxy wasn't exercised.

## What still costs time

- **Go's build cache depends on the runner.** `go build` hashes the source directory into its
  cache keys when `-trimpath` isn't set, and every runner has its own workspace path
  (`/srv/gha-runners/<runner>/_work/...`). The restored cache is complete, but only the runner
  that wrote the entries gets hits: `go build ./...` took 8 s on `docker-runners-1-1` (which
  ran the cold build), 26 s and 41 s on `1-4` and `1-3`, and 4 s in the serial rounds on
  `1-4` after it had built caddy once. GitHub's path is always `/home/runner/work/...`, so it
  gets 3–4 s everywhere. Workflows can avoid this with `-trimpath` (`GOFLAGS=-trimpath`).
- **The Rust cache is per runner too.** `Swatinem/rust-cache` keys on the absolute path of
  `target/`, so only `docker-runners-1-3` (which saved it in the cold round) restored it:
  32 s and 17 s builds there, 50–67 s on the other runners (`No cache found`). The toolchain
  is installed per runner as well (`rustup toolchain install` 11–15 s on a runner without it,
  0 s with it, 7 s on GitHub).
- **CPU.** CPU-bound steps (tests, compiles without cache) take about twice as long with four
  jobs on the 6-core Ryzen 5 PRO 4650G as on GitHub's dedicated EPYC/Xeon cores, and are level
  with one job at a time.
- **`npm ci`** took 7 s vs. 4 s, even with npm's cache in the shared `~/.npm`.

## Hardware

Recorded by the job itself (`lscpu`, `nproc`, `free -m`, cgroup limits):

| | GitHub-hosted (`ubuntu-latest`, private repository) | Self-hosted (`fullplus-host-1`) |
|---|---|---|
| vCPU per job | 2 | 2 (cgroup `cpu.max 200000 100000`, `GOMAXPROCS=2`) |
| RAM per job | 7.9 GB | 4 GB cgroup limit (`free` shows the host's 62 GB) |
| CPU | AMD EPYC 7763 / 9V45 / 9V74, Intel Xeon 8573C / 8370C / 6973P-C / 6975P-C (varies per job) | AMD Ryzen 5 PRO 4650G (6 cores, 12 threads) |
| Jobs sharing the CPU | none visible | the 4 runners of the host (2 vCPU cap each) |
| Image | `ubuntu-24.04` | `full-plus` flavor, persistent mode, shared cache across the host's LXCs |

GitHub gives **public** repositories 4 vCPU / 16 GB on `ubuntu-latest`. These numbers are from a
private repository, so they compare against the smaller 2 vCPU machine.

## Method

- Workflow: [`.github/workflows/benchmark.yml`](../.github/workflows/benchmark.yml). Matrix
  `side: [hosted, self-hosted]` × `workload: [node, go, rust, docker]`. Every action is pinned
  by commit SHA, every workload by commit:
  - Node: `axios/axios` v1.21.0 (`aa54a5e`), `setup-node` with `cache: npm`, Node 22.21.0
  - Go: `caddyserver/caddy` v2.11.9 (`0d98cae`), `setup-go` with its default cache, Go 1.26.0
  - Rust: `BurntSushi/ripgrep` 15.2.0 (`e89fff8`), `Swatinem/rust-cache` with `cache-bin: false`,
    Rust 1.90.0
  - Docker: `distribution/distribution` v3.1.2 (`3220848`), `docker/build-push-action` with
    `cache-from/to: type=gha,mode=max`, base images from Docker Hub
- Excluded tests: `tests/unit/adapters/fetch.test.js` (axios) and
  `TestServer_ClosedRequestBodyDoesNotDesyncHTTP1` (caddy) fail on both sides regardless of the
  runner.
- Every job first checks out its own repository with full history. The benchmark repository
  was seeded with the history of `expressjs/express` (10 MB pack) so the Git checkout cache has
  something to do.
- Cold vs. warm: caches are per branch and the default branch never runs the benchmark, so a
  new branch (`bench/r1`, `bench/r2`) starts with an empty Actions cache on both sides. The
  first run is cold, the warm runs reuse the same branch and keys. Self-hosted jobs were pinned
  to `[self-hosted, fullplus-host-1]`; every run only started when all four runners of that
  host were online and idle. No other job used that host during the runs.
- Timings come from the GitHub API (`/actions/runs/<id>/jobs`, `started_at`/`completed_at` of the
  job and of each step, 1 s resolution).

Runs in [Quavon-dev/runner-benchmark](https://github.com/Quavon-dev/runner-benchmark) (private):

| Round | Round 2 run | Round 1 run | Parallel |
|---|---|---|---|
| cold | [42279430665](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42279430665) | [42212224153](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42212224153) | 8 |
| warm 1 | [42280057884](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42280057884) | [42212954279](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42212954279) | 8 |
| warm 2 | [42280546044](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42280546044) | [42213289411](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42213289411) | 8 |
| warm 3 | [42281153835](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42281153835) | [42213684040](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42213684040) | 8 |
| serial 1 | [42281598441](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42281598441) | [42214509519](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42214509519) | 1 |
| serial 2 | [42283262150](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42283262150) | [42215960466](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42215960466) | 1 |

## Reproduce

1. Put `.github/workflows/benchmark.yml` into a repository your runners serve. Never run it on
   the default branch, so a new branch is always cold.
2. Cold round: `git push origin HEAD:bench/r2`, then
   `gh workflow run benchmark.yml --ref bench/r2 -f self_hosted_runs_on='["self-hosted","linux"]'`.
   Repeat the same command for the warm rounds; add `-f max_parallel=1` for one job at a time.
3. Collect and summarize (needs `gh` and Python 3):

   ```bash
   python3 benchmarks/collect.py <owner/repo> cold=<id> warm1=<id> warm2=<id> warm3=<id> serial1=<id> serial2=<id> >results.json
   python3 benchmarks/summarize.py r2=results.json r1=benchmarks/results/2026-11-06.json >summary.json
   ```

   Round names ending in a number are grouped (`warm1..3` → `warm`). `summarize.py` takes one
   `name=results.json` per benchmark round; `chart.py` draws `r2` and, faded, `r1`.

## Caveats

- One self-hosted host, one day, three warm and two serial repetitions per round. Differences
  below ~15% are noise; the hosted side alone moved that much between the rounds.
- The self-hosted side is not fully cold even in the cold round: the shared package caches
  (`~/.cache`, `~/.npm`), the Git checkout cache and the Docker Hub mirror can't be emptied
  without hurting other jobs, and the `moby/buildkit` image was already on the runners. The
  Actions cache and the shared tool cache (new since round 1) started empty, and the Go base
  image came from Docker Hub.
- The host is outside Azure, where GitHub-hosted runners run. Network location and bandwidth
  were not measured; every download (GitHub, npm, Go proxy, crates.io, Docker Hub) is part of
  the step times above.
- Go and Rust warm times depend on which runner a job lands on (see above), so their medians
  swing with the runner assignment.
- The Git checkout cache saves about 1 s on a 10 MB repository. It matters for large
  repositories, which this benchmark doesn't have.

## Round 1 (before the cache fixes)

Same day, same workflow, branch `bench/r1`, `runs-on: [self-hosted, linux]` (all
self-hosted jobs ran on `fullplus-host-1`). What was wrong on the self-hosted
side, all fixed for round 2 (see [docs/caching.md](../docs/caching.md)):

- **Go cache restore failed.** `GOMODCACHE` points into the shared `~/.cache`; `setup-go`
  extracted its cache over 22,205 read-only module files that already existed, `tar` failed and
  the full cache was uploaded again every job (11 s). Fixed with `GOFLAGS=-modcacherw`.
- **Tool downloads repeated per runner.** Each runner container had its own
  `/opt/hostedtoolcache`, so Node and Go were downloaded again on every runner that hadn't seen
  the version (`setup-node` 18 s vs. 8 s on GitHub). The tool cache is shared now.
- **`rust-cache` removed `rustup` and `cargo` from the runners.** With `cache-bin: true` its post
  step deleted the binaries in the persistent `CARGO_HOME`, so both serial Rust jobs failed with
  `rustup: command not found`. The workflow sets `cache-bin: false`, and the runners restore the
  binaries after `rust-cache`.
- **The Rust cache missed on every warm run**, because all four Rust jobs ran on different
  runners. That is unchanged (per-runner workspace paths) and showed up again in round 2.
- **BuildKit builders pulled directly.** Builders created by `docker/setup-buildx-action`
  didn't use the mirrors; they now get a `buildkitd.toml` that points at them.
