---
title: benchmark-lite.sh
weight: 4
---

A lightweight version of `benchmark.sh` designed to run on any machine with Docker — no CPU pinning, no special hardware requirements, and all load generators run in containers.

```bash
./scripts/benchmark-lite.sh <framework> [profile] [--save] [--load-threads N]
```

## Options

| Parameter | Description |
|-----------|-------------|
| `<framework>` | Name of the framework directory under `frameworks/` |
| `[profile]` | Optional — run only this test profile (e.g. `baseline`, `json`) |
| `--save` | Persist results to `results/` and rebuild site data |
| `--load-threads N` | Override the number of threads for gcannon and h2load (default: half your CPU cores) |

## Differences from benchmark.sh

| | `benchmark.sh` | `benchmark-lite.sh` |
|---|---|---|
| **CPU pinning** | Per-profile `--cpuset-cpus` | None |
| **Connections** | Varies (512–16384) | Fixed 512 (upload: 128) |
| **Load generator threads** | 64 (gcannon), 128 (h2load) | Half of available cores (auto) |
| **gcannon** | Native binary with `taskset` | Docker container |
| **h2load** | Native binary | Docker container |
| **API-4 / API-16** | Included | Not available (require dedicated CPUs) |
| **System tuning** | CPU governor, TCP buffers, cache flush | Same (best-effort, skips if no sudo) |

## Requirements

- **Docker Engine** — the only hard requirement
- **gcannon source** — expected at `../gcannon` relative to the repo root (override with `GCANNON_SRC=/path/to/gcannon`). Built automatically as a Docker image on first run.
- **h2load** — built automatically as a Docker image from `docker/h2load.Dockerfile` on first run.

No native toolchain, no io_uring, no specific CPU topology needed.

## Example

```bash
# Run baseline test (dry run)
./scripts/benchmark-lite.sh actix baseline

# Run all subscribed tests and save results
./scripts/benchmark-lite.sh --save actix

# Override thread count for a low-core machine
./scripts/benchmark-lite.sh --load-threads 2 actix baseline

# Run and save a specific test
./scripts/benchmark-lite.sh --save actix json
```

## How it works

1. **Auto-builds load generator images** if they don't exist (`gcannon:latest`, `h2load:latest`)
2. **Builds the framework image** and starts the container with `--network host`
3. **Runs load tests** with gcannon/h2load/oha in Docker containers — no CPU pinning, half the cores allocated to avoid starving the server
4. **Best-of-3 runs** per test, same metrics collection as `benchmark.sh`

Results are comparable across machines for relative ranking, but absolute RPS numbers will differ from the official leaderboard which runs on dedicated hardware with CPU isolation.
