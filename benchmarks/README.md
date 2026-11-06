# Benchmark: GitHub-hosted vs. self-hosted runners

Real open-source builds, run on the same day (2026-11-06) on GitHub's `ubuntu-latest` and on
runners installed with this repository. Raw numbers: [`results/2026-11-06.json`](results/2026-11-06.json),
summary: [`summary.json`](summary.json).

**Short version:** on this hardware the self-hosted runners were **not** faster. With all four
runners of one host busy at once they were 7–68% slower. With one job at a time they were
about level, and 30% faster for the Docker build. Two workloads lost most of their warm cache on the
self-hosted side because of how two popular actions behave on persistent runners (see
[What did not work](#what-did-not-work)).

## Results

Total job time in seconds (job start to job end, queue time excluded). Warm: median of 3 runs
(min–max). Speedup = hosted / self-hosted, above 1 means self-hosted is faster.

| Workload | Hosted cold | Self-hosted cold | Hosted warm | Self-hosted warm | Speedup warm |
|---|---:|---:|---:|---:|---:|
| Node: axios install, build, unit tests | 121 | 145 | 126 (117–127) | 147 (129–159) | 0.86 |
| Go: caddy build, tests | 241 | 293 | 66 (63–67) | 132 (96–147) | 0.50 |
| Rust: ripgrep release build | 81 | 92 | 36 (36–43) | 112 (102–130) | 0.32 |
| Docker: distribution image, `type=gha` cache | 167 | 232 | 148 (107–159) | 160 (131–173) | 0.93 |

Warm, one job at a time (`max_parallel=1`, 2 runs, median):

| Workload | Hosted | Self-hosted | Speedup |
|---|---:|---:|---:|
| Node | 113 | 140 (113, 167) | 0.81 |
| Go | 63 | 94 (58, 130) | 0.67 |
| Docker | 148.5 | 114.5 (106, 123) | 1.30 |
| Rust | 40 | failed, see below | – |

The first serial run had the host to itself and came out level or ahead (Node 113 vs 114,
Go 58 vs 63, Docker 106 vs 144). The second one was slower on every job for no reason
visible in the logs, so treat the serial numbers as indicative only.

Queue time was 1–3 s on both sides in every round.

### Where the time goes (warm medians, seconds)

| Step | Hosted | Self-hosted |
|---|---:|---:|
| Node: `setup-node` (download Node 22.21.0, restore npm cache) | 8 | 18 |
| Node: unit tests (CPU bound) | 89 | 93 |
| Go: `setup-go` (download Go, restore cache) | 29 | 37 |
| Go: `go build ./...` | 3 | 26 |
| Go: post `setup-go` (cache save) | 0 | 11 |
| Rust: `cargo build --release` | 19 | 80 |
| Docker: `setup-buildx` | 9 | 3 |
| Docker: build | 129 | 135 |
| Checkout of the own repository (full history, 10 MB) | 2 | 1 |

## Hardware

Recorded by the job itself (`lscpu`, `nproc`, `free -m`, cgroup limits):

| | GitHub-hosted (`ubuntu-latest`, private repository) | Self-hosted (`fullplus-host-1`) |
|---|---|---|
| vCPU per job | 2 | 2 (cgroup `cpu.max 200000 100000`, `GOMAXPROCS=2`) |
| RAM per job | 7.9 GB | 4 GB cgroup limit (`free` shows the host's 62 GB) |
| CPU | AMD EPYC 7763 / 9V45 / 9V74, Intel Xeon 8573C / 6973P-C (varies per job) | AMD Ryzen 5 PRO 4650G (6 cores, 12 threads) |
| Jobs sharing the CPU | none visible | the 4 runners of the host (2 vCPU cap each) |
| Image | `ubuntu-24.04` | `full-plus` flavor, persistent mode, shared cache |

GitHub gives **public** repositories 4 vCPU / 16 GB on `ubuntu-latest`. These numbers are from a
private repository, so they compare against the smaller 2 vCPU machine.

## Method

- Workflow: [`.github/workflows/benchmark.yml`](../.github/workflows/benchmark.yml). Matrix
  `side: [hosted, self-hosted]` × `workload: [node, go, rust, docker]`. Every action is pinned
  by commit SHA, every workload by commit:
  - Node: `axios/axios` v1.21.0 (`aa54a5e`), `setup-node` with `cache: npm`, Node 22.21.0
  - Go: `caddyserver/caddy` v2.11.9 (`0d98cae`), `setup-go` with its default cache, Go 1.26.0
  - Rust: `BurntSushi/ripgrep` 15.2.0 (`e89fff8`), `Swatinem/rust-cache`, Rust 1.90.0
  - Docker: `distribution/distribution` v3.1.2 (`3220848`), `docker/build-push-action` with
    `cache-from/to: type=gha,mode=max`, base images from Docker Hub
- Excluded tests: `tests/unit/adapters/fetch.test.js` (axios) and
  `TestServer_ClosedRequestBodyDoesNotDesyncHTTP1` (caddy) fail on both sides regardless of the
  runner.
- Every job first checks out its own repository with full history. The benchmark repository
  was seeded with the history of `expressjs/express` (10 MB pack) so the Git checkout cache has
  something to do.
- Cold vs. warm: caches are per branch and the default branch never runs the benchmark, so a
  new branch (`bench/r1`) starts with an empty Actions cache on both sides. Round 1 is cold,
  rounds 2–4 reuse the same branch and keys. The self-hosted rounds only started when all
  runners of `fullplus-host-1` were idle. No other job used that host during the runs.
- Timings come from the GitHub API (`/actions/runs/<id>/jobs`, `started_at`/`completed_at` of the
  job and of each step, 1 s resolution).

Run in [Quavon-dev/runner-benchmark](https://github.com/Quavon-dev/runner-benchmark) (private):

| Round | Run | Parallel |
|---|---|---|
| cold | [42212224153](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42212224153) | 8 |
| warm 1 | [42212954279](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42212954279) | 8 |
| warm 2 | [42213289411](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42213289411) | 8 |
| warm 3 | [42213684040](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42213684040) | 8 |
| serial 1 | [42214509519](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42214509519) | 1 |
| serial 2 | [42215960466](https://github.com/Quavon-dev/runner-benchmark/actions/runs/42215960466) | 1 |

## Reproduce

1. Put `.github/workflows/benchmark.yml` into a repository your runners serve. Never run it on
   the default branch, so a new branch is always cold.
2. Cold round: `git push origin HEAD:bench/r1`, then
   `gh workflow run benchmark.yml --ref bench/r1 -f self_hosted_runs_on='["self-hosted","linux"]'`.
   Repeat the same command for the warm rounds; add `-f max_parallel=1` for one job at a time.
3. Collect and summarize (needs `gh` and Python 3):

   ```bash
   python3 benchmarks/collect.py <owner/repo> cold=<id> warm1=<id> warm2=<id> warm3=<id> >results.json
   python3 benchmarks/summarize.py results.json >summary.json
   ```

   Round names ending in a number are grouped (`warm1..3` → `warm`).

## What did not work

- **Rust cache missed on every warm run.** `rust-cache` caches `target/` by absolute path. On
  these runners the workspace is `/srv/gha-runners/<runner name>/_work/...`, and the Actions cache
  version is a hash of the paths, so a cache saved by `docker-runners-1-2` is invisible to
  `1-1`, `1-3` and `1-4`. The four Rust jobs ran on four different runners, so all of them
  compiled from scratch (the cache was saved each time, 51 MB at 166 MB/s to the local server).
  On GitHub the path is always `/home/runner/work/...` and warm builds took 19 s instead of 58 s.
- **`rust-cache` removed `rustup` and `cargo` from the runners.** With `cache-bin: true` (its default)
  the post step deletes every file that was in `CARGO_HOME/bin` before the job, so the cache
  only holds binaries the job installed. On GitHub the VM is thrown away afterwards. Here
  `CARGO_HOME=/usr/share/rust/.cargo` is inside the persistent runner container, so the next Rust
  job on that runner fails with `rustup: command not found` (both serial rounds). The workflow
  now sets `cache-bin: false`; runners that already lost the binaries need a restart
  (`gha-runners restart`).
- **Go cache restore failed.** `GOMODCACHE` points into the shared `~/.cache`, which already
  held the modules from earlier jobs. `setup-go` extracts its 500 MB cache over it, `tar` hits
  22,205 read-only files that already exist, and the restore is reported as failed. The job
  then re-uploads the full cache (11 s) every time. The build still profited from the shared
  build cache (26 s instead of 201 s cold), but the hosted runner with a clean restore needed 3 s.
- **Tool downloads repeat per runner.** `setup-node` and `setup-go` download into each runner
  container's own `/opt/hostedtoolcache`, so a job on a runner that has not seen that version
  yet downloads it again (Node: 18 s vs. 8 s on GitHub).
- **The Docker build is mostly not cacheable.** The base and `apk` layers came from the `type=gha`
  cache on both sides, but distribution's Go compile step bind-mounts the whole context
  (including `.git`) and its `type=cache` mounts are not exported, so it compiles every time.
  That step is pure CPU (67 s hosted, 131 s self-hosted in warm 2).
- **CPU.** CPU-bound steps (tests, compiles without cache) depend on the CPU. Four jobs at once
  on a 6-core desktop CPU against dedicated EPYC/Xeon cores is a contest the self-hosted side
  loses. With the host to itself it was level.

## Caveats

- One self-hosted host, one day, three warm repetitions. Differences below ~15% are noise.
- The self-hosted host is outside Azure, where GitHub-hosted runners run.
  Network location and bandwidth were not measured; every download (GitHub, npm, Go proxy,
  crates.io, Docker Hub) is part of the step times above.
- The shared package caches (`~/.cache`, `~/.npm`) can't be emptied without hurting other jobs,
  so only the first run ever is fully cold there. The Docker Hub mirror was not reset either.
- The Git checkout cache worked (`.git` was present in every warm self-hosted job) but saved
  about 1 s on a 10 MB repository. It matters for large repositories, which this benchmark
  doesn't have.
- The second serial round was slower than the first on every self-hosted job without a visible
  cause.
- The Rust toolchain stays installed in a persistent runner container, which helps later jobs on
  the same runner; it is not one of the caches described in [docs/caching.md](../docs/caching.md).
