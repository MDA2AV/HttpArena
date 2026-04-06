## Description



---

**PR Commands** — comment on this PR to trigger (requires collaborator approval):

| Command | Description |
|---------|-------------|
| `/validate -f <framework>` | Run the 18-point validation suite |
| `/benchmark -f <framework>` | Run all benchmark tests |
| `/benchmark -f <framework> -t <test>` | Run a specific test |
| `/benchmark -f <framework> --save` | Run and save results (updates leaderboard on merge) |

Always specify `-f <framework>`. Results are automatically compared against the current leaderboard.

---

<details>
<summary><strong>Run benchmarks locally</strong></summary>

You can validate and benchmark your framework on your own machine using `benchmark-lite.sh` — a lightweight version that works on any machine with Docker (no CPU pinning, fixed connections).

```bash
# Validate
./scripts/validate.sh <framework>

# Benchmark a specific test
./scripts/benchmark-lite.sh <framework> baseline

# Benchmark all tests the framework subscribes to
./scripts/benchmark-lite.sh <framework>

# Override load generator thread count (default: half your cores)
./scripts/benchmark-lite.sh --load-threads 4 <framework> baseline
```

**Requirements:** Docker Engine. The load generators (gcannon, h2load) are built automatically as Docker images on first run. gcannon source is expected at `../gcannon` relative to the repo root (override with `GCANNON_SRC=/path/to/gcannon`).

</details>
