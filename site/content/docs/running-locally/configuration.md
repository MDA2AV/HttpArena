---
title: Configuration
weight: 5
---

Everything the benchmark driver can be told to do via environment variables, plus the shape of a profile definition. For the full flag-by-flag walkthrough see [benchmark.sh](scripts/benchmark) and [benchmark-lite.sh](scripts/benchmark-lite).

## Run settings

Defined in `scripts/lib/common.sh`. Override by exporting before you run the script, or inline: `THREADS=8 ./scripts/benchmark.sh actix baseline`.

| Variable | Default | Description |
|---|---|---|
| `DURATION` | `5s` | Load-test duration per run (`-d`/`-D` passed through to the tool). |
| `RUNS` | `3` | Measurement iterations per (profile, connection count). Best wins. |
| `THREADS` | `64` | gcannon / wrk worker threads. |
| `H2THREADS` | `64` | h2load worker threads (HTTP/2, h2c gRPC). |
| `H3THREADS` | `64` | h2load-h3 worker threads (HTTP/3 over QUIC). |
| `SKIP_TUNE` | `false` | When `true`, skips kernel/hardware tuning (CPU governor, socket limits) that requires `sudo`. Useful for local development. |

In `benchmark-lite.sh`, `THREADS` defaults to `max(nproc / 2, 1)` and `H2THREADS` / `H3THREADS` mirror `$THREADS`. Pass `--load-threads N` to override all three in one shot.

## Ports

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | HTTP/1.1 plaintext (all `h1*` profiles + `echo-ws`); also h2c for gRPC (`unary-grpc`, `stream-grpc` — prior-knowledge on the same socket). |
| `H2PORT` | `8443` | HTTPS / HTTP/2 over TLS (`baseline-h2`, `static-h2`, gateway + production-stack), HTTP/3 over QUIC (`baseline-h3`, `static-h3`, `gateway-h3`), and gRPC-TLS (`unary-grpc-tls`, `stream-grpc-tls`). |
| `H1TLS_PORT` | `8081` | HTTP/1.1 + TLS, used only by the `json-tls` profile (ALPN `http/1.1`). |
| `H2C_PORT` | `8082` | HTTP/2 cleartext prior-knowledge for the `baseline-h2c` and `json-h2c` profiles. Must be a dedicated listener that refuses HTTP/1.1 — the validator checks this explicitly. |

Every framework `Dockerfile` reads the same defaults from its env, so you rarely need to change these.

## Load-generator mode

| Variable | Default | Description |
|---|---|---|
| `LOADGEN_DOCKER` | `false` | When `true`, every load generator runs from its Docker image instead of the host binary. Builds missing images automatically from `docker/*.Dockerfile`. Forced `true` by `benchmark-lite.sh`. |
| `GCANNON_MODE` | `native` | `native` or `docker`. Implied by `LOADGEN_DOCKER`. |
| `GCANNON_CPUS` | dynamic | CPU list the load generators run on. Native mode wraps calls in `taskset -c $GCANNON_CPUS`; docker mode passes it via `--cpuset-cpus`. Defaults to the upper half of available cores on smaller machines to avoid resource contention with the server. |

## Tool binaries and images

Each load generator has a pair of variables — native binary name and docker image tag:

| Native (`$TOOL`) | Docker (`$TOOL_IMAGE`) | Used for | Source |
|---|---|---|---|
| `GCANNON=gcannon` | `GCANNON_IMAGE=gcannon:latest` | h1, pipelined, limited-conn, json, json-comp, upload, api-4/16, async-db, echo-ws | `docker/gcannon.Dockerfile` |
| `H2LOAD=h2load` | `H2LOAD_IMAGE=h2load:latest` | baseline-h2, static-h2, unary-grpc, unary-grpc-tls, gateway-64 | `docker/h2load.Dockerfile` (Ubuntu + glibc, **not** alpine) |
| `H2LOAD_H3=h2load-h3` | `H2LOAD_H3_IMAGE=h2load-h3:local` | baseline-h3, static-h3 | `docker/h2load-h3.Dockerfile` (quictls + ngtcp2 + nghttp3) |
| `WRK=wrk` | `WRK_IMAGE=wrk:local` | static, json-tls | `docker/wrk.Dockerfile` |
| `GHZ=ghz` | `GHZ_IMAGE=ghz:local` | stream-grpc, stream-grpc-tls, gRPC readiness probe | `docker/ghz.Dockerfile` |

## Postgres sidecar

Started automatically when the framework subscribes to `async-db`, `api-4`, `api-16`, or `gateway-64`.

| Variable | Default | Description |
|---|---|---|
| `PG_CONTAINER` | `httparena-postgres` | Container name. |
| `DATABASE_URL` | `postgres://bench:bench@localhost:5432/benchmark` | Exported into the framework container so the app can connect. |

The sidecar uses `postgres:18` (Debian, glibc) with `-c max_connections=256` and is seeded from `data/pgdb-seed.sql`.

## Profile definitions

Profiles live in `scripts/lib/profiles.sh`. Format:

```
pipeline | req_per_conn | cpu_limit | connections | endpoint
```

- **pipeline** — gcannon `-p` value. `1` = sequential, `16` = pipelined.
- **req_per_conn** — gcannon `-r` value. `0` = keep-alive forever; a positive number forces reconnect every N requests (exercises the accept path).
- **cpu_limit** — cpuset written to the framework container's `--cpuset-cpus`. Blank = no pinning.
- **connections** — comma-separated list; each value becomes a separate iteration.
- **endpoint** — dispatch key. Tells `endpoint_tool()` which load generator to use and `gcannon_build_args()` (etc.) how to shape the request.

`benchmark-lite.sh` overrides `PROFILES` and `PROFILE_ORDER` with a smaller subset and blanks the `cpu_limit` column; everything else parses identically.

## Profile → tool dispatch

From `endpoint_tool()` in `scripts/lib/profiles.sh`:

| Endpoint | Tool |
|---|---|
| `static`, `json-tls` | wrk |
| `h2`, `static-h2`, `h2c`, `json-h2c`, `gateway-64`, `grpc`, `grpc-tls`, `production-stack` | h2load |
| `h3`, `static-h3`, `gateway-h3` | h2load-h3 |
| `grpc-stream`, `grpc-stream-tls` | ghz |
| everything else (`""`, `pipeline`, `upload`, `api-4`, `api-16`, `async-db`, `crud`, `json`, `json-compressed`, `ws-echo`) | gcannon |

## Small-machine overrides

The defaults in `benchmark.sh` assume the reference 64-core benchmark host. On a laptop, three variables usually get you to something reasonable:

```bash
THREADS=8 H2THREADS=16 H3THREADS=4 ./scripts/benchmark.sh actix baseline
```

If native gcannon / h2load / h2load-h3 aren't installed, flip the whole thing to docker mode instead of installing each tool:

```bash
LOADGEN_DOCKER=true ./scripts/benchmark.sh actix --save
```

Or just use `benchmark-lite.sh`, which is this combination pre-baked.
