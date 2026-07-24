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

Always specify `-f <framework>`; the flags combine in any order. Results come back as a comment with a per-profile table of RPS, p99, CPU and memory.

**What the deltas are measured against.** By default, this framework's own results published on `main` - answering *"did this change help?"*. When you are tuning a variant or a successor entry, `--compare` re-bases them on another entry instead:

```
/benchmark -f genhttp-11 --compare genhttp
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

**Requirements:** Docker Engine on Linux. Load generators (gcannon, h2load, h2load-h3, wrk, ghz) are built as self-contained Docker images on first run.

</details>
