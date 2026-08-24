## Description



---

**PR Commands** — comment on this PR to trigger (requires collaborator approval):

| Command | Description |
|---------|-------------|
| `/benchmark -f <framework>` | Run every test the framework subscribes to |
| `/benchmark -f <framework> -t <test>` | Run one test only |
| `/benchmark -f <framework> --save` | Run and save results (updates the leaderboard on merge) |
| `/benchmark -f <framework> -t <test> --save` | Run one test and save results |
| `/benchmark -f <framework> --compare <other>` | Measure the deltas against another framework instead of this one |
| `/benchmark-multiple -f <fw1>,<fw2>,...` | Benchmark several frameworks in one run — takes `-t` and `--save` too; saved results land in a single commit |
| `/benchmark-multiple --save` | No `-f` needed: benchmark and save every framework the PR touches |
| `/benchmark-test -t <test>` | Benchmark **all** enabled frameworks subscribed to `<test>` and save the results |

For `/benchmark`, always specify `-f <framework>`; the flags combine in any order. Results come back as a comment with a per-profile table of RPS, p99, CPU and memory — one table per framework on multi runs. A new benchmark comment while a run is in flight queues behind it (one deep) instead of cancelling it. For multi-framework PRs (dependency bumps, same-language refactors) prefer `/benchmark-multiple`, which runs everything in a single job and commits all saved results together, so no run overwrites another. `--compare` works on single-framework runs only.

**What the deltas are measured against.** By default, this framework's own results published on `main` - answering *"did this change help?"*. When you are tuning a variant or a successor entry, `--compare` re-bases them on another entry instead:

```
/benchmark -f genhttp-11 --compare genhttp-11-kestrel
```

The reply states which baseline it used, and profiles the other framework does not run show `n/a` rather than a delta.

---

<details>
<summary><strong>Run benchmarks locally</strong></summary>

You can validate and benchmark your framework locally with the lite script — no CPU pinning, fixed connection counts, all load generators run in Docker.

```bash
./scripts/validate.sh <framework>
./scripts/benchmark-lite.sh <framework> baseline
./scripts/benchmark-lite.sh --load-threads 4 <framework>
```

**Requirements:** Docker Engine on Linux. Load generators (gcannon, h2load, h2load-h3, wrk) are built as self-contained Docker images on first run.

</details>
