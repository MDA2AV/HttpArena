---
title: Configuration
seo_title: "Benchmark Configuration Reference"
description: "Every environment variable the benchmark driver accepts, plus the anatomy of a profile definition in profiles.sh."
weight: 5
---

Everything the benchmark driver can be told to do via environment variables, plus the shape of a profile definition. For the full flag-by-flag walkthrough see [benchmark.sh](../scripts/benchmark/) and [benchmark-lite.sh](../scripts/benchmark-lite/). The defaults below are the bench host's; a [host profile](../host-profiles/) replaces many of them for other machines.

## Run settings

Defined in `scripts/lib/common.sh`. Override by exporting before you run the script, or inline: `THREADS=8 ./scripts/benchmark.sh actix baseline`.

| Variable | Default | Description |
|---|---|---|
| `DURATION` | `5s` | Load-test duration per run (`-d`/`-D` passed through to the tool). |
| `RUNS` | `3` | Measurement iterations per (profile, connection count). Best wins. |
| `THREADS` | `64` | gcannon / wrk / zrk worker threads. |
| `ASYNC_THREADS` | `64` | gcannon worker threads for the `async` profile only. |
| `H2THREADS` | `64` | h2load worker threads (HTTP/2, h2c gRPC). |
| `H3THREADS` | `64` | h2load-h3 worker threads (HTTP/3 over QUIC). |
| `SKIP_TUNE` | `false` | When `true`, skips kernel/hardware tuning (CPU governor, socket limits) that requires `sudo`. Useful for local development. |

## Ports

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | HTTP/1.1 plaintext (all `h1*` profiles + `echo-ws`); also h2c for gRPC (`unary-grpc` - prior-knowledge on the same socket). |
| `H2PORT` | `8443` | HTTPS / HTTP/2 over TLS (`baseline-h2`, `static-h2`, gateway + production-stack), HTTP/3 over QUIC (`baseline-h3`, `static-h3`, `gateway-h3`), and gRPC-TLS (`unary-grpc-tls`). |
| `H1TLS_PORT` | `8081` | HTTP/1.1 + TLS for the `json-tls`, `static-tls` and `8gbit` profiles (ALPN `http/1.1`). |
| `H2C_PORT` | `8082` | HTTP/2 cleartext prior-knowledge for the `baseline-h2c` and `json-h2c` profiles. The listener may also answer HTTP/1.1; the benchmark and the validator only ever speak h2c to it. |

Every framework `Dockerfile` reads the same defaults from its env, so you rarely need to change these.

## Load-generator mode

| Variable | Default | Description |
|---|---|---|
| `LOADGEN_DOCKER` | `false` | When `true`, every load generator runs from its Docker image instead of the host binary. Builds missing images automatically from `docker/*.Dockerfile`. Set by the `lite` and `rpi` host profiles. |
| `GCANNON_MODE` | `native` | `native` or `docker`. Implied by `LOADGEN_DOCKER`. |
| `GCANNON_CPUS` | dynamic | CPU list the load generators run on. Native mode wraps calls in `taskset -c $GCANNON_CPUS`; docker mode passes it via `--cpuset-cpus`. Defaults to the upper half of available cores on smaller machines to avoid resource contention with the server. |

## Tool binaries and images

Each load generator has a pair of variables - native binary name and docker image tag:

| Native (`$TOOL`) | Docker (`$TOOL_IMAGE`) | Used for | Source |
|---|---|---|---|
| `GCANNON=gcannon` | `GCANNON_IMAGE=gcannon:latest` | baseline, pipelined, limited-conn, json-comp, async-db, async, fortunes, echo-ws, echo-ws-pipeline, echo-ws-limited | `docker/gcannon.Dockerfile` |
| `H2LOAD=h2load` | `H2LOAD_IMAGE=h2load:latest` | baseline-h2, static-h2, baseline-h2c, json-h2c, unary-grpc, unary-grpc-tls, gateway-64, production-stack | `docker/h2load.Dockerfile` (Ubuntu + glibc, **not** alpine) |
| `H2LOAD_H3=h2load-h3` | `H2LOAD_H3_IMAGE=h2load-h3:local` | baseline-h3, static-h3, gateway-h3 | `docker/h2load-h3.Dockerfile` (quictls + ngtcp2 + nghttp3) |
| `WRK=wrk` | `WRK_IMAGE=wrk:local` | static-tls, json-tls | `docker/wrk.Dockerfile` |
| `ZRK=zrk` | `ZRK_IMAGE=zrk:local` | latency-1m, latency-10k, latency-500k-8cpu, 8gbit | `docker/zrk.Dockerfile` |

## Postgres sidecar

Started automatically when the framework subscribes to `async-db`, `fortunes`, `gateway-64`, `gateway-h3` or `production-stack`.

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

- **pipeline** - gcannon `-p` value. `1` = sequential, `16` = pipelined.
- **req_per_conn** - gcannon `-r` value. `0` = keep-alive forever; a positive number forces reconnect every N requests (exercises the accept path).
- **cpu_limit** - cpuset written to the framework container's `--cpuset-cpus`. Blank = no pinning.
- **connections** - comma-separated list; each value becomes a separate iteration.
- **endpoint** - dispatch key. Tells `endpoint_tool()` which load generator to use and `gcannon_build_args()` (etc.) how to shape the request.

`PROFILE_ORDER` lists the profiles that run, in order; a profile filter on the command line must name profiles from it. A [host profile](../host-profiles/) overrides entries of `PROFILES` and replaces `PROFILE_ORDER`.

## Profile → tool dispatch

From `endpoint_tool()` in `scripts/lib/profiles.sh`:

| Endpoint | Tool |
|---|---|
| `static-tls`, `json-tls` | wrk |
| `latency-1m`, `latency-10k`, `latency-500k-8cpu`, `8gbit` | zrk |
| `h2`, `static-h2`, `h2c`, `json-h2c`, `gateway-64`, `grpc`, `grpc-tls`, `production-stack` | h2load |
| `h3`, `static-h3`, `gateway-h3` | h2load-h3 |
| everything else (`""`, `pipeline`, `async-db`, `async`, `fortunes`, `json-compressed`, `ws-echo`) | gcannon |

## Host profiles

| Variable | Default | Description |
|---|---|---|
| `HOST_PROFILE` | unset | Name of a host profile in `scripts/lib/hosts/` (`lite`, `rpi`, or your own). Unset = bench-host defaults. See [Host profiles](../host-profiles/). |
| `READY_TIMEOUT` | `30` | Seconds to wait for a framework to answer before its profile is skipped. `rpi` sets 120. |
| `FAIL_FAST` | unset | When `true`, a framework that does not come up for one profile skips its remaining profiles. Set by `rpi`. |
| `SKIP_H3_LOADGEN` | unset | When `true`, the `h2load-h3` image is not built in Docker mode. For hosts that run no HTTP/3 profile. |

With a host profile, `--save` writes to `results-hosts/<name>/` (container logs in `results-hosts/<name>/_logs/`) and leaves `results/` and the site data alone.

## Small-machine overrides

The defaults in `benchmark.sh` assume the reference 64-core benchmark host. On any other machine, use a host profile:

```bash
./scripts/benchmark-lite.sh actix baseline    # same as HOST_PROFILE=lite ./scripts/benchmark.sh actix baseline
```

For a one-off tweak, the variables above can also be set directly - e.g. fewer threads with Docker load generators and the bench-host profile table:

```bash
LOADGEN_DOCKER=true THREADS=8 H2THREADS=16 H3THREADS=4 ./scripts/benchmark.sh actix baseline
```

For a machine you benchmark regularly, [write a host profile](../host-profiles/#writing-your-own) instead.
