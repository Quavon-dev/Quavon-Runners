# Benchmarks

GitHub-hosted `ubuntu-latest` against self-hosted runners installed with this repository,
on real open-source builds (Node: axios, Go: caddy, Rust: ripgrep, Docker: distribution).
Full method, raw numbers and step timings: [benchmarks/README.md](../benchmarks/README.md).

![Job time of GitHub-hosted and self-hosted runners, cold, warm in parallel and warm one job at a time](assets/benchmark.svg)

**In this round the self-hosted runners were not faster.**

- **All jobs in parallel** (4 self-hosted runners sharing one 6-core Ryzen 5 PRO 4650G,
  2 vCPU each): self-hosted took longer on every workload, from 1.1× (Docker) to 3.1×
  (Rust) the time of the hosted runner.
- **One job at a time:** the first serial round was level or ahead (Node 114 s vs. 113 s,
  Go 58 s vs. 63 s, Docker 106 s vs. 144 s). The second was slower on every self-hosted
  job for no reason visible in the logs, so the medians above only show Docker ahead.
  Treat the serial numbers as indicative.

What to keep in mind:

- One host, one day, three warm repetitions. Differences below ~15% are noise.
- The rounds ran **before** two fixes: Go's module cache restore failed over the shared
  `~/.cache` (now `GOFLAGS=-modcacherw`), and every runner downloaded its own tool versions
  (the tool cache is now shared, see [Caching](caching.md)). Both cost the self-hosted side
  time in the Go and Node jobs.
- The Rust warm runs missed their cache because `Swatinem/rust-cache` keys on the
  per-runner workspace path, and the serial Rust runs failed because `rust-cache` deleted
  `rustup` from the persistent runners (since restored, and the workflow now sets
  `cache-bin: false`).
- CPU-bound steps depend on the CPU. Four jobs at once on a 6-core desktop CPU against
  dedicated EPYC/Xeon cores is a contest the self-hosted side loses.
- GitHub gives **public** repositories 4 vCPU / 16 GB; these numbers compare against the
  2 vCPU machine of a private repository.

## Regenerate the chart

After a new round (see [Reproduce](../benchmarks/README.md#reproduce)):

```bash
python3 benchmarks/summarize.py results.json >benchmarks/summary.json
python3 benchmarks/chart.py
```

`chart.py` reads `benchmarks/summary.json` and writes `docs/assets/benchmark.svg`. It needs
only Python 3. Update the subtitle in `chart.py` when the hardware or setup changes.
