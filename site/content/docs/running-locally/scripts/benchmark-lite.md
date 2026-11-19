---
title: benchmark-lite.sh
seo_title: "benchmark-lite.sh: Local Benchmark Driver"
description: "The laptop-friendly way to run benchmarks: benchmark.sh with the lite host profile - Docker-only load generators, no CPU pinning, fewer threads and a smaller profile set."
weight: 4
---

`scripts/benchmark-lite.sh` runs [`benchmark.sh`](../benchmark/) with the `lite` [host profile](../../host-profiles/) (`scripts/lib/hosts/lite.sh`). It is made for a laptop with Docker and nothing else installed: the driver, metrics and output format are the same as for a full run, only scaled to the machine.

## Synopsis

```bash
./scripts/benchmark-lite.sh [framework] [profile[,profile...]] [--save] [--load-threads N]
```

| Argument | Description |
|---|---|
| `[framework]` | Framework directory name. If omitted, every framework with `"enabled": true` in its `meta.json` is run in turn. |
| `[profile]` | Optional - one profile or a comma-separated list. Must be in the [lite profile set](#profile-set). |
| `--save` | Keep the results in `results-hosts/lite/`. Without it, numbers are printed and nothing is written. |
| `--load-threads N` | Load-generator threads for this run (all generators). `THREADS=N` in the environment does the same. |

Arguments can appear in any order.

`./scripts/benchmark-lite.sh actix baseline` is the same as `HOST_PROFILE=lite ./scripts/benchmark.sh actix baseline`.

## What lite changes

| | `benchmark.sh` | `benchmark-lite.sh` |
|---|---|---|
| Load generators | Native binaries by default | Docker, always |
| CPU pinning | Server and generators on separate cores | None - every container sees every core |
| Generator threads | 64 | `nproc / 2` (at least 1) |
| Profiles | 27, several connection counts each | 13, one connection count each |
| Framework argument | Required | Optional - all enabled frameworks if omitted |
| `--save` writes to | `results/` + site data | `results-hosts/lite/` only |

Everything else is shared with `benchmark.sh`: host tuning, the Postgres sidecar for `async-db`, readiness checks, result format.

## Profile set

| Profile | Pipeline | Req/conn | Connections | Tool | Endpoint |
|---|---|---|---|---|---|
| `baseline` | 1 | ∞ | 512 | gcannon | `/baseline11` |
| `pipelined` | 16 | ∞ | 512 | gcannon | `/pipeline` |
| `limited-conn` | 1 | 10 | 512 | gcannon | `/baseline11` |
| `json-comp` | 1 | ∞ | 512 | gcannon | `/json/{count}` + compression |
| `8gbit` | 1 | ∞ | 128 | zrk | `POST /echo` (TLS) |
| `async-db` | 1 | ∞ | 512 | gcannon | `/async-db?limit=N` |
| `baseline-h2` | 1 | ∞ | 512 | h2load | `/baseline2` (TLS) |
| `static-h2` | 1 | ∞ | 512 | h2load | `/static/*` (TLS) |
| `baseline-h3` | 1 | ∞ | 64 | h2load-h3 | `/baseline2` (QUIC) |
| `static-h3` | 1 | ∞ | 64 | h2load-h3 | `/static/*` (QUIC) |
| `unary-grpc` | 1 | ∞ | 512 | h2load | `GetSum` h2c |
| `unary-grpc-tls` | 1 | ∞ | 512 | h2load | `GetSum` TLS |
| `echo-ws` | 1 | ∞ | 512 | gcannon `--ws` | `/ws` |

Not included: `json-tls`, `static-tls`, `async`, `latency-1m`, `latency-10k`, `latency-500k-8cpu`, `fortunes`, `baseline-h2c`, `json-h2c`, `gateway-64`, `gateway-h3`, `production-stack`, `echo-ws-pipeline`, `echo-ws-limited`. A framework subscribed to them simply skips them here.

## First run

The first invocation (or the first after a `docker rmi`) builds every load-generator image from `docker/*.Dockerfile`:

- `gcannon:latest` - clones `github.com/MDA2AV/gcannon` main, pulls `liburing-2.9`, compiles.
- `h2load:latest` - Ubuntu 24.04 + `apt install nghttp2-client` (glibc build, not musl).
- `h2load-h3:local` - Ubuntu 24.04 + `quictls` + `nghttp3` + `ngtcp2` + `nghttp2 --enable-http3` from source. Takes 5–10 minutes the first time.
- `wrk:local` - Ubuntu 24.04 + `wrk` source build.
- `zrk:local` - the zrk release for the host's architecture (x86_64 or aarch64).

The images are built before host tuning, because tuning restarts the Docker daemon and buildkit DNS takes a few seconds to recover - long enough to break a `git clone` inside a build container.

To force a rebuild (e.g. to pick up a new gcannon commit):

```bash
docker rmi gcannon:latest
./scripts/benchmark-lite.sh actix baseline
```

## Requirements

Docker Engine, bash and python3. You need no load generator on the host, no `io_uring`-capable kernel (the gcannon container carries its own `liburing 2.9`) and no compiler toolchain.

Host tuning (CPU governor, sysctl, Docker daemon restart, MTU, page-cache drop) uses `sudo` where needed and warns and continues without it. Runs without tuning are noisier but still fine for relative comparisons; `SKIP_TUNE=true` skips it altogether.

## Examples

```bash
# Every enabled framework, every lite profile (dry run)
./scripts/benchmark-lite.sh

# One framework, one profile
./scripts/benchmark-lite.sh actix baseline

# Keep the results (results-hosts/lite/)
./scripts/benchmark-lite.sh actix --save

# 4 load-generator threads on a low-core machine
./scripts/benchmark-lite.sh --load-threads 4 actix baseline

# Shorter iterations while working on a framework
DURATION=2s RUNS=1 ./scripts/benchmark-lite.sh actix baseline
```

Lite runs are for smoke tests and for comparing frameworks, or two builds of one framework, on your own machine. Absolute numbers will not match the published leaderboard, which comes from a dedicated 64-core host with CPU isolation and native load generators.
