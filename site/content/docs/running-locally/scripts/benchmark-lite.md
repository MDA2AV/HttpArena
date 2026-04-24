---
title: benchmark-lite.sh
weight: 4
---

`scripts/benchmark-lite.sh` is the local-dev variant of `benchmark.sh`. Same module structure, same metrics, same output layout — but with defaults tuned for "laptop with Docker and nothing else installed".

## What's different

| | `benchmark.sh` | `benchmark-lite.sh` |
|---|---|---|
| Default load generators | Native binaries | **Always** docker (forced — no env override) |
| CPU pinning | Per-profile `--cpuset-cpus` | None — all containers see every core |
| `THREADS` default | 64 | `nproc / 2` |
| `H2THREADS` / `H3THREADS` default | 64 / 64 | Same as `THREADS` |
| Profile set | 26 profiles | 15 — skips `api-4`, `api-16`, `json-tls`, `crud`, `baseline-h2c`, `json-h2c`, `gateway-64`, `gateway-h3`, `production-stack`, `stream-grpc`, `stream-grpc-tls` |
| Connection counts | Varies (512, 1024, 4096, 16384, …) | One per profile (mostly 512; upload 128; h3 64) |
| Framework selection | One framework, always | Optional — runs every enabled framework if omitted |

Everything that isn't listed stays identical: `--save` behavior, host tuning, result layout, postgres sidecar for `async-db`, `gcannon_parse` version fallbacks, etc.

## Synopsis

```bash
./scripts/benchmark-lite.sh [framework] [profile] [--save] [--load-threads N]
```

| Argument | Description |
|---|---|
| `[framework]` | Framework directory name. If omitted, every framework with `"enabled": true` in its `meta.json` is run in sequence. |
| `[profile]` | Optional — restrict to a single profile. |
| `--save` | Persist result JSONs + rebuild site data. |
| `--load-threads N` | Shortcut for `THREADS=N H2THREADS=N H3THREADS=N` for a specific run. |

Arguments can appear in any order; flags and positionals are separated during parsing.

## First run

First time you invoke it (or after a `docker rmi`), the script builds every load-generator image it needs from `docker/*.Dockerfile`:

- `gcannon:latest` — clones `github.com/MDA2AV/gcannon` main, pulls `liburing-2.9`, compiles.
- `h2load:latest` — Ubuntu 24.04 + `apt install nghttp2-client` (glibc build, not musl).
- `h2load-h3:local` — Ubuntu 24.04 + builds `quictls` + `nghttp3` + `ngtcp2` + `nghttp2 --enable-http3` from source. Takes 5–10 minutes the first time.
- `wrk:local` — Ubuntu 24.04 + `wrk` source build.
- `ghz:local` — `ghz` from `github.com/bojand/ghz@v0.121.0`, static CGO_DISABLED build.

All images are built **before** the host tuning step, because `system_tune()` restarts the Docker daemon and buildkit DNS takes a few seconds to recover — long enough to break `git clone` inside a build container.

To force a rebuild (e.g. to pick up a new gcannon commit):

```bash
docker rmi gcannon:latest
./scripts/benchmark-lite.sh actix baseline
```

## Environment variables

Everything in [benchmark.sh → Environment variables](../benchmark/#environment-variables) applies, with these lite-specific defaults / overrides:

| Variable | Default in lite | Notes |
|---|---|---|
| `LOADGEN_DOCKER` | `true` (forced, non-overridable) | `export` at the top of the script. |
| `GCANNON_MODE` | `docker` (forced) | Same. |
| `GCANNON_CPUS` | `0-$(nproc-1)` | Effectively "all cores" — the `--cpuset-cpus` value covers the whole CPU. |
| `THREADS` | `$(( $(nproc) / 2 ))` (min 1) | Half the cores, leaving room for the framework container. |
| `H2THREADS` | Same as `THREADS` | |
| `H3THREADS` | Same as `THREADS` | |

## Profile set

| Profile | Pipeline | Req/conn | Connections | Tool | Endpoint |
|---|---|---|---|---|---|
| `baseline` | 1 | ∞ | 512 | gcannon | `/baseline11` |
| `pipelined` | 16 | ∞ | 512 | gcannon | `/pipeline` |
| `limited-conn` | 1 | 10 | 512 | gcannon | `/baseline11` |
| `json` | 1 | ∞ | 512 | gcannon | `/json/{count}` |
| `json-comp` | 1 | ∞ | 512 | gcannon | `/json/{count}` + compression |
| `upload` | 1 | ∞ | 128 | gcannon | `/upload` |
| `static` | 1 | 10 | 512 | wrk | `/static/*` |
| `async-db` | 1 | ∞ | 512 | gcannon | `/async-db?limit=N` |
| `baseline-h2` | 1 | ∞ | 512 | h2load | `/baseline2` (TLS) |
| `static-h2` | 1 | ∞ | 512 | h2load | `/static/*` (TLS) |
| `baseline-h3` | 1 | ∞ | 64 | h2load-h3 | `/baseline2` (QUIC) |
| `static-h3` | 1 | ∞ | 64 | h2load-h3 | `/static/*` (QUIC) |
| `unary-grpc` | 1 | ∞ | 512 | h2load | `GetSum` h2c |
| `unary-grpc-tls` | 1 | ∞ | 512 | h2load | `GetSum` TLS |
| `echo-ws` | 1 | ∞ | 512 | gcannon `--ws` | `/ws` |

## Requirements

The only hard requirement is **Docker Engine**. Everything else — gcannon, h2load, h2load-h3, wrk, ghz — is built automatically inside containers. You don't need `io_uring` on the host kernel (the gcannon container carries its own `liburing 2.9`), you don't need `nghttp2-client` installed, and you don't need a Rust/Go toolchain.

Host tuning (CPU governor, sysctl, docker daemon restart, MTU, page-cache drop) is still best-effort — it uses `sudo` where needed and warns + continues if you don't have it. Numbers without tuning are noisier but still usable for relative comparisons.

## Examples

```bash
# Every enabled framework, every subset profile (dry run)
./scripts/benchmark-lite.sh

# One framework, one profile
./scripts/benchmark-lite.sh actix baseline

# Persist results and rebuild site data
./scripts/benchmark-lite.sh actix --save

# 4-thread load generators for a low-core machine
./scripts/benchmark-lite.sh --load-threads 4 actix baseline

# Shorter iterations while debugging a framework
DURATION=2s RUNS=1 ./scripts/benchmark-lite.sh actix baseline
```

Lite runs are great for CI-style smoke tests and for comparing frameworks relative to each other on your own hardware. Absolute numbers will not match the published leaderboard — that's produced on a dedicated 128-core host with CPU isolation and native load generators.
