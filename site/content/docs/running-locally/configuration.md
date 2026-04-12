---
title: Configuration
weight: 5
---

## Global parameters

These are set at the top of `scripts/benchmark.sh` and apply to all profiles:

| Parameter | Default | Env override | Description |
|-----------|---------|--------------|-------------|
| `THREADS` | 64 | `THREADS=12` | Threads for gcannon and gcannon-based load tests |
| `H2THREADS` | 128 | `H2THREADS=64` | Threads for h2load (HTTP/2, gRPC) |
| `DURATION` | 5s | — | Duration per benchmark run |
| `RUNS` | 3 | — | Runs per configuration (best kept) |
| `PORT` | 8080 | — | HTTP/1.1 port |
| `H2PORT` | 8443 | — | HTTPS / HTTP/2 / HTTP/3 / gRPC-TLS port |

## Load generator paths

| Variable | Default | Description |
|----------|---------|-------------|
| `GCANNON` | `gcannon` | Path to gcannon binary |
| `H2LOAD` | `h2load` | Path to h2load binary |
| `OHA` | `$HOME/.cargo/bin/oha` | Path to oha binary |
| `GHZ` | `ghz` | Path to ghz binary |

Override with environment variables if your binaries are in a non-standard location:

```bash
GCANNON=/usr/local/bin/gcannon H2LOAD=/usr/local/bin/h2load ./scripts/benchmark.sh express
```

## Profile definitions

Each profile defines: pipeline depth, requests per connection, CPU limit, connection counts, and endpoint type.

| Profile | Pipeline | Req/conn | CPU pinning | Connections | Endpoint |
|---------|----------|----------|-------------|-------------|----------|
| baseline | 1 | 0 | 0-31,64-95 | 512, 4096 | `/baseline11` |
| pipelined | 16 | 0 | 0-31,64-95 | 512, 4096 | `/pipeline` |
| limited-conn | 1 | 10 | 0-31,64-95 | 512, 4096 | `/baseline11` |
| json | 1 | 0 | 0-31,64-95 | 4096 | `/json/{count}` (7 counts) |
| json-comp | 1 | 0 | 0-31,64-95 | 512, 4096, 16384 | `/json/{count}?m=N` + `Accept-Encoding: gzip, br` |
| upload | 1 | 0 | 0-31,64-95 | 32, 256 | `/upload` |
| api-4 | 1 | 5 | 0-3 | 256 | mixed (baseline, json, async-db) |
| api-16 | 1 | 5 | 0-7,64-71 | 1024 | mixed (baseline, json, async-db) |
| static | 1 | 200 | 0-31,64-95 | 1024, 4096, 6800 | `/static/*` (20 files, wrk) |
| async-db | 1 | 0 | 0-31,64-95 | 1024 | `/async-db?limit=N` (5 limits) |
| baseline-h2 | 1 | 0 | 0-31,64-95 | 256, 1024 | `/baseline2` (h2load) |
| static-h2 | 1 | 0 | 0-31,64-95 | 256, 1024 | `/static/*` (h2load) |
| unary-grpc | 1 | 0 | 0-31,64-95 | 256, 1024 | gRPC `GetSum` (h2load h2c) |
| unary-grpc-tls | 1 | 0 | 0-31,64-95 | 256, 1024 | gRPC `GetSum` (h2load TLS) |
| echo-ws | 1 | 0 | 0-31,64-95 | 512, 4096, 16384 | `/ws` (gcannon `--ws`) |

- **Pipeline** — requests sent back-to-back per connection before waiting for responses
- **Req/conn** — requests per connection before disconnect and reconnect (0 = keep-alive, no limit)
- **CPU pinning** — container `--cpuset-cpus` value (pins to specific CPU cores)

## Overriding for local testing

The thread count defaults (64 / 128) are tuned for the dedicated 64-core benchmark server. On a local machine with fewer cores, override them:

```bash
THREADS=8 H2THREADS=16 ./scripts/benchmark.sh express baseline
```
