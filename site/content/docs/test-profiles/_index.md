---
title: Test Profiles
seo_title: "Test Profiles"
description: "Every HttpArena benchmark profile, each isolating a different performance dimension so frameworks are compared on equal terms."
weight: -1
toc: false
---

HttpArena runs every framework through multiple benchmark profiles. Each profile isolates a different performance dimension, ensuring frameworks are compared fairly across varied workloads.

Your framework must implement endpoints depending on which test profiles it participates in. Plaintext HTTP/1.1 is served on **port 8080**, HTTP/1.1 over TLS (`json-tls`, `static-tls`, `8gbit`) on **port 8081**, cleartext HTTP/2 (`baseline-h2c`, `json-h2c`) on **port 8082**, and HTTP/2 and HTTP/3 over TLS on **port 8443**.

Many profiles run at more than one connection count to show how frameworks scale under increasing concurrency.

## API Specification

All benchmark endpoints are described in machine-readable OpenAPI 3.0 specifications. Each spec covers request/response schemas, status codes, standard and tuned implementation rules, and links back to the relevant documentation pages.

The endpoints are split across two files:

| Spec | Profiles covered | |
|------|-----------------|---|
| [openapi.json](/openapi.json) | All HTTP/1.1, HTTP/2, HTTP/3, gRPC, and WebSocket profiles | [Browse](https://redocly.github.io/redoc/?url=https://http-arena.com/openapi.json) |
| [openapi-gateway.json](/openapi-gateway.json) | Gateway profiles (production-stack) | [Browse](https://redocly.github.io/redoc/?url=https://http-arena.com/openapi-gateway.json) |

## Benchmark parameters

Five load generators are dispatched per profile - each one is built for a specific protocol + workload shape. See [Load Generators](../load-generators/) for per-tool details.

| Parameter | Value |
|-----------|-------|
| Load generators | `gcannon` (HTTP/1.1, WebSocket), `wrk` (`static-tls`, `json-tls`), `zrk` (fixed-rate: `latency-*`, `8gbit`), `h2load` (HTTP/2, h2c, gRPC, gateway), `h2load-h3` (HTTP/3 / QUIC) |
| Threads | 64 for every generator (`$THREADS` / `$H2THREADS` / `$H3THREADS`) |
| Duration | 5s default; `async` and `async-db` 10s, `latency-*` 20s |
| Runs | 3 per (profile, connection count) - the best run is kept (highest RPS, or highest score on the fixed-rate profiles) |
| Networking | Docker `--network host` for all containers (server + load generator + Postgres + Redis sidecars) |

## Data mounts

Data files are **mounted automatically** by the benchmark runner - your Dockerfile does not need to include them. The following paths are available inside the container at runtime:

| Path | Description |
|------|-------------|
| `/data/dataset.json` | 50-item dataset for `/json/{count}` |
| `/data/static/` | 20 static assets for `/static/*` (HTML, JS, CSS, SVG, WebP, woff2, JSON). 15 assets ship with pre-built `.gz` and `.br` sibling files (e.g. `app.js`, `app.js.gz`, `app.js.br`) so frameworks that support precompressed serving can skip on-the-fly compression. The 5 already-binary formats (`hero.webp`, `thumb1.webp`, `thumb2.webp`, `bold.woff2`, `regular.woff2`) have no precompressed variants. See the [Static TLS](h1/static-tls/) profile for how to wire Accept-Encoding lookup. |
| `/certs/server.crt`, `/certs/server.key` | TLS certificate and key for every TLS listener (HTTP/1.1 on 8081, HTTP/2 and HTTP/3 on 8443) |

## Environment variables

Set by the benchmark runner when the relevant profile runs - your process will see them via `os.environ` / `std::env::var` / equivalent.

| Variable | Profiles | Value |
|----------|----------|-------|
| `DATABASE_URL` | `async-db`, `fortunes` | Postgres connection string (`postgres://bench:bench@127.0.0.1:5432/benchmark`) |
| `DATABASE_MAX_CONN` | same as above | `256` - the Postgres sidecar's `max_connections`; size your pool ≤ this |

Gateway and `production-stack` profiles are compose-orchestrated, so their services receive additional env (e.g. `JWT_SECRET` for the production-stack auth sidecar) via their `compose.*.yml` files rather than through the runner. See the per-profile pages under [Gateway](gateway/) for details.

{{< cards >}}
  {{< card link="h1" title="H/1.1" subtitle="Isolated single-endpoint benchmarks and multi-endpoint workload mixes over plain TCP." icon="lightning-bolt" >}}
  {{< card link="h2" title="H/2" subtitle="Baseline, static file and JSON benchmarks over HTTP/2 with stream multiplexing, over TLS and cleartext (h2c)." icon="globe-alt" >}}
  {{< card link="gateway" title="Gateway" subtitle="Multi-service deployments: proxy + server (H2/H3) and full CRUD production stack with JWT auth + cache-aside." icon="server" >}}
  {{< card link="h3" title="H/3" subtitle="Baseline and static file benchmarks over QUIC for frameworks with native H/3 support." icon="globe-alt" >}}
  {{< card link="grpc" title="gRPC" subtitle="Unary RPC throughput over HTTP/2, cleartext and TLS, using Protocol Buffers serialization." icon="globe-alt" >}}
  {{< card link="ws" title="WebSocket" subtitle="WebSocket echo throughput measuring frame processing performance." icon="globe-alt" >}}
{{< /cards >}}
