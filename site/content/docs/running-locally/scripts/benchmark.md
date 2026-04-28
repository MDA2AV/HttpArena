---
title: benchmark.sh
weight: 3
---

`scripts/benchmark.sh` is the full-fidelity benchmark driver. It runs one framework across every profile it subscribes to, tunes the host, collects metrics, and (with `--save`) persists results to `results/` and the site data JSONs.

The driver itself is small (~320 lines of orchestration) — all of the real work lives in the composable library modules under `scripts/lib/`.

## Synopsis

```bash
./scripts/benchmark.sh <framework> [profile] [--save]
```

| Argument | Description |
|---|---|
| `<framework>` | Name of the framework directory under `frameworks/`. Required. |
| `[profile]` | Optional — run only this profile (e.g. `baseline`, `async-db`, `echo-ws`). If omitted, runs every profile the framework subscribes to. |
| `--save` | Persist results. Without it, you get a dry run — numbers printed, nothing written. |

`--save` can appear in any position. There is no other positional argument.

## What a run does, step by step

1. **Cleanup** — stops and removes any leftover `httparena-*` containers.
2. **Load-generator images** (docker mode only) — builds any missing `gcannon`, `h2load`, `h2load-h3`, `wrk`, or `ghz` image from `docker/*.Dockerfile`. Runs *before* host tuning on purpose: tuning restarts the Docker daemon, and buildkit's DNS takes a few seconds to recover afterwards, long enough to break a `git clone` inside a build container.
3. **Framework build** — `frameworks/<fw>/build.sh` if present, otherwise `docker build frameworks/<fw>`.
4. **Host tuning** (`scripts/lib/system.sh`):
   - CPU governor → `performance` via `cpupower` (falls back to writing `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`).
   - `net.core.somaxconn=65535`, `tcp_max_syn_backlog=65535`, `netdev_max_backlog=65535`, `rmem_max=wmem_max=7500000` (QUIC).
   - `ip link set lo mtu 1500` — realistic Ethernet MTU, not the kernel's default 65536.
   - `systemctl restart docker` — guarantees every subsequent container starts from a fresh daemon state.
   - `echo 3 > /proc/sys/vm/drop_caches`.
5. **Postgres sidecar** — started if the framework subscribes to any of `async-db`, `api-4`, `api-16`, `crud`, `gateway-64`, `gateway-h3`, `production-stack`. Uses `postgres:18` (Debian, glibc), tmpfs-backed, seeded from `data/pgdb-seed.sql`, `max_connections=256`, host network.
6. **Profile loop** — for each subscribed profile × each connection count:
   - Starts the framework container (or `docker compose up` for gateway profiles).
   - Waits up to 30s for the right endpoint to respond.
   - Builds the tool-specific argument vector.
   - Runs `$RUNS` measurement iterations (default 3), keeps the best by rps.
   - Each iteration: starts `docker stats` polling, runs the load generator (`timeout 45s`), stops polling, parses output.
   - For ghz, a 2s warmup precedes the first measurement.
   - Raw load-generator output from every run is written to `site/static/logs/<profile>/<conns>/<framework>.<tool>.run<N>.txt` — useful when a parser misbehaves.
7. **Save** (`--save` only) — writes `results/<profile>/<conns>/<framework>.json` + framework `docker logs` to `site/static/logs/<profile>/<conns>/<framework>.log`.
8. **Restore** — trap runs `framework_stop`, `gateway_down`, `postgres_stop`, then restores the original CPU governor and loopback MTU.
9. **Rebuild site data** (`--save` only) — re-runs `scripts/rebuild_site_data.py` to regenerate `site/data/<profile>-<conns>.json` and `site/data/frameworks.json`.

## Flags

| Flag | Description |
|---|---|
| `--save` | Persist result JSONs and rebuild site data. Default is dry run. |

Everything else is controlled through environment variables (see below).

## Environment variables

Set via `VAR=value ./scripts/benchmark.sh ...` or `export VAR=value`.

### Run settings

| Variable | Default | Description |
|---|---|---|
| `DURATION` | `5s` | `-d`/`-D` value passed to each load generator. |
| `RUNS` | `3` | Measurement iterations per (profile, conns). Best result wins. |
| `THREADS` | `64` | Load-generator threads for gcannon, wrk, and the default path. |
| `H2THREADS` | `64` | h2load worker threads (h2, h2c gRPC). |
| `H3THREADS` | `64` | h2load-h3 worker threads (HTTP/3 over QUIC). |

### Ports

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | HTTP/1.1 plaintext (all `h1*` profiles + `echo-ws`); also h2c for gRPC (`unary-grpc`, `stream-grpc`). |
| `H2PORT` | `8443` | HTTPS / HTTP/2 TLS (`baseline-h2`, `static-h2`, gateway + production-stack), HTTP/3 QUIC (`baseline-h3`, `static-h3`, `gateway-h3`), gRPC-TLS (`unary-grpc-tls`, `stream-grpc-tls`). |
| `H1TLS_PORT` | `8081` | HTTP/1.1 + TLS — only used by the `json-tls` profile. |
| `H2C_PORT` | `8082` | HTTP/2 cleartext prior-knowledge for `baseline-h2c` and `json-h2c`. Must refuse HTTP/1.1 — the validator checks this. |

### Load generator selection

Switch every load generator from native binary to the pre-built Docker image in one env var:

```bash
LOADGEN_DOCKER=true ./scripts/benchmark.sh aspnet-minimal
```

| Variable | Default | Description |
|---|---|---|
| `LOADGEN_DOCKER` | `false` | When `true`, every load generator runs from its Docker image instead of the host binary. Builds missing images automatically. |
| `GCANNON_MODE` | `native` | `native` or `docker`. `LOADGEN_DOCKER=true` sets this to `docker` for you. |
| `GCANNON_CPUS` | `32-63,96-127` | Cores the load generators are pinned to (via `taskset` in native mode or `--cpuset-cpus` in docker mode). Framework containers use the *other* half of the CPU topology. |

### Tool binaries + images

| Variable | Default | Used for |
|---|---|---|
| `GCANNON` | `gcannon` | Native binary — baseline, pipelined, limited-conn, json, json-comp, upload, api-4/16, async-db, crud, echo-ws. |
| `GCANNON_IMAGE` | `gcannon:latest` | Docker image when `LOADGEN_DOCKER=true`. |
| `H2LOAD` | `h2load` | Native binary — baseline-h2, static-h2, baseline-h2c, json-h2c, unary-grpc, unary-grpc-tls, gateway-64, production-stack. |
| `H2LOAD_IMAGE` | `h2load:latest` | Docker image (Ubuntu 24.04 + glibc build; do **not** use the alpine/musl image — it's 20–40% slower). |
| `H2LOAD_H3` | `h2load-h3` | Native binary — baseline-h3, static-h3, gateway-h3. |
| `H2LOAD_H3_IMAGE` | `h2load-h3:local` | Docker image with `quictls` + `nghttp3` + `ngtcp2` + `nghttp2 --enable-http3` built from source. |
| `WRK` | `wrk` | Native binary — static, json-tls. |
| `WRK_IMAGE` | `wrk:local` | Docker image. |
| `GHZ` | `ghz` | Native binary — stream-grpc, stream-grpc-tls, gRPC readiness probe. |
| `GHZ_IMAGE` | `ghz:local` | Docker image. |

### Postgres sidecar

| Variable | Default | Description |
|---|---|---|
| `PG_CONTAINER` | `httparena-postgres` | Name of the sidecar container. |
| `DATABASE_URL` | `postgres://bench:bench@localhost:5432/benchmark` | Passed to framework containers for `async-db`, `crud`, `api-4`, `api-16`, `gateway-64`, `gateway-h3`, `production-stack`. |

## Profiles

Each profile is one line in `scripts/lib/profiles.sh` with the format:

```
pipeline | req_per_conn | cpu_limit | connections | endpoint
```

| Profile | Pipeline | Req/conn | CPU pinning | Connections | Tool | Endpoint |
|---|---|---|---|---|---|---|
| `baseline` | 1 | ∞ | `0-31,64-95` | 512, 4096 | gcannon | `/baseline11` |
| `pipelined` | 16 | ∞ | `0-31,64-95` | 512, 4096 | gcannon | `/pipeline` |
| `limited-conn` | 1 | 10 | `0-31,64-95` | 512, 4096 | gcannon | `/baseline11` (reconnect every 10 req) |
| `json` | 1 | ∞ | `0-31,64-95` | 4096 | gcannon | `/json/{1..50}` — 7 body sizes |
| `json-comp` | 1 | ∞ | `0-31,64-95` | 512, 4096, 16384 | gcannon | `/json/{count}` + `Accept-Encoding: gzip, br` |
| `json-tls` | 1 | ∞ | `0-31,64-95` | 4096 | wrk | `/json/{count}` over TLS on `H1TLS_PORT` |
| `upload` | 1 | ∞ | `0-31,64-95` | 32, 256 | gcannon | `/upload` — 500K / 2M / 10M / 20M bodies, `-r 5` |
| `api-4` | 1 | 5 | `0-3` | 256 | gcannon | 8-template mix (baseline / json / async-db) |
| `api-16` | 1 | 5 | `0-7,64-71` | 1024 | gcannon | 8-template mix |
| `static` | 1 | 200 | `0-31,64-95` | 1024, 4096, 6800 | wrk | 20 files via `static-rotate.lua` |
| `async-db` | 1 | ∞ | `0-31,64-95` | 1024 | gcannon | 5 limit variants (5/10/20/35/50), `-r 25` |
| `baseline-h2` | 1 | ∞ | `0-31,64-95` | 256, 1024 | h2load | `/baseline2` on `H2PORT` TLS |
| `static-h2` | 1 | ∞ | `0-31,64-95` | 256, 1024 | h2load | `/static/*` on `H2PORT` TLS |
| `baseline-h3` | 1 | ∞ | `0-31,64-95` | 64 | h2load-h3 | `/baseline2` on `H2PORT` QUIC |
| `static-h3` | 1 | ∞ | `0-31,64-95` | 64 | h2load-h3 | `/static/*` on `H2PORT` QUIC |
| `unary-grpc` | 1 | ∞ | `0-31,64-95` | 256, 1024 | h2load | `benchmark.BenchmarkService/GetSum` h2c |
| `unary-grpc-tls` | 1 | ∞ | `0-31,64-95` | 256, 1024 | h2load | same, TLS |
| `stream-grpc` | 1 | ∞ | `0-31,64-95` | 64 | ghz | `StreamSum` h2c, 5000 msgs/call |
| `stream-grpc-tls` | 1 | ∞ | `0-31,64-95` | 64 | ghz | same, TLS |
| `gateway-64` | 1 | ∞ | `0-31,64-95` | 256, 1024 | h2load | 20-URI mix behind nginx via `docker compose` |
| `echo-ws` | 1 | ∞ | `0-31,64-95` | 512, 4096, 16384 | gcannon `--ws` | `/ws` |

**Subscription:** a framework only runs profiles listed in its `meta.json` `tests` array. Profiles it's not subscribed to are silently skipped.

## Examples

```bash
# Dry run — everything the framework subscribes to, nothing saved
./scripts/benchmark.sh actix

# Save a full run
./scripts/benchmark.sh actix --save

# One profile only
./scripts/benchmark.sh actix baseline --save

# Run with every load generator in docker (useful if native gcannon / h2load-h3 aren't installed)
LOADGEN_DOCKER=true ./scripts/benchmark.sh actix --save

# Short runs for iterating on a framework
DURATION=2s RUNS=1 ./scripts/benchmark.sh actix baseline

# Override load-gen threading for a small machine
THREADS=8 H2THREADS=16 H3THREADS=8 ./scripts/benchmark.sh actix baseline
```

## Output layout

```
results/<profile>/<conns>/<framework>.json     # metrics (RPS, p99, CPU, mem, status buckets)
site/static/logs/<profile>/<conns>/<framework>.log            # docker logs of the framework container
site/static/logs/<profile>/<conns>/<framework>.<tool>.runN.txt # raw load-generator stdout per iteration
site/data/<profile>-<conns>.json                # aggregated for the leaderboard
site/data/frameworks.json                       # framework metadata
site/data/current.json                          # host/OS/commit snapshot
```
