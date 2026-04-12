---
title: benchmark.sh
weight: 3
---

Run benchmarks for a framework across one or all test profiles. Tunes system settings, builds the Docker image, runs load tests with multiple connection counts, and collects results.

```bash
./scripts/benchmark.sh <framework> [profile] [--save]
```

## Options

| Parameter | Description |
|-----------|-------------|
| `<framework>` | Name of the framework directory under `frameworks/` |
| `[profile]` | Optional — run only this test profile (e.g. `baseline`, `json`, `upload`) |
| `--save` | Persist results to `results/` and rebuild site data in `site/data/` |

Without `--save`, results are displayed but not persisted.

## What it does

1. **System tuning** — sets CPU governor to `performance`, increases TCP buffer sizes, and flushes filesystem caches
2. **Docker build** — builds the framework image (or runs `build.sh` if present)
3. **Sidecar setup** — starts a Postgres container for `async-db`, `api-4`, and `api-16` profiles
4. **Load testing** — for each profile the framework is subscribed to:
   - Runs at each connection count defined for the profile
   - Executes 3 runs per configuration, keeps the best result
   - Uses the appropriate load generator: gcannon (HTTP/1.1), h2load (HTTP/2, gRPC), oha (HTTP/3), gcannon `--ws` (WebSocket)
5. **Result collection** — captures RPS, latency (avg/p99), CPU, memory, bandwidth, and reconnect counts
6. **Save** (with `--save`) — writes JSON result files to `results/<profile>/<connections>/<framework>.json` and rebuilds aggregated site data

## Example

```bash
# Dry run — display results only
./scripts/benchmark.sh express baseline

# Run all profiles and save
./scripts/benchmark.sh --save express

# Run a single profile and save
./scripts/benchmark.sh --save express json
```

## Benchmark parameters

Each profile defines its own configuration:

- **Pipeline depth** — 1 (sequential) or 16 (pipelined)
- **Connection counts** — varies by profile (e.g. 512/4096 for baseline, 256/512 for HTTP/3)
- **Duration** — 5 seconds per run (10s for sync-db/async-db, 15s for workload profiles)
- **Runs** — 3 per configuration, best kept
