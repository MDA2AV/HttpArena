## Description



---

**PR Commands** — comment on this PR to trigger (requires collaborator approval):

| Command | Description |
|---------|-------------|
| `/benchmark -f <framework>` | Run all benchmark tests |
| `/benchmark -f <framework> -t <test>` | Run a specific test |
| `/benchmark -f <framework> --save` | Run and save results (updates leaderboard on merge) |
| `/benchmark -f <framework> --compare <other>` | Compare against another framework's published results instead of this one's |

Always specify `-f <framework>`. Results are automatically compared against the current leaderboard.

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
