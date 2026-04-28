---
title: Test Profiles
weight: -1
toc: false
---

HttpArena runs every framework through multiple benchmark profiles. Each profile isolates a different performance dimension, ensuring frameworks are compared fairly across varied workloads.

Your framework must implement endpoints depending on which test profiles it participates in. All HTTP/1.1 endpoints are served on **port 8080**. HTTPS/H2/H3 endpoints are served on **port 8443**.

Each profile is run at multiple connection counts to show how frameworks scale under increasing concurrency.

## Benchmark parameters

Five load generators are dispatched per profile — each one is built for a specific protocol + workload shape. See [Load Generators](../load-generators/) for per-tool details.

| Parameter | Value |
|-----------|-------|
| Load generators | `gcannon` (HTTP/1.1, upload, WebSocket), `wrk` (static + json-tls rotation), `h2load` (HTTP/2, h2c, gateway), `h2load-h3` (HTTP/3 / QUIC), `ghz` (gRPC) |
| Threads | 64 for `gcannon` / `wrk` / `h2load` / `h2load-h3` (`$THREADS` / `$H2THREADS` / `$H3THREADS`); `ghz` scales workers dynamically as `connections × 4` |
| Duration | 5s default; `async-db` 10s; `api-4`, `api-16`, `crud` 15s (hardcoded in the profile dispatcher) |
| Runs | 3 per (profile, connection count) — best RPS wins |
| Networking | Docker `--network host` for all containers (server + load generator + Postgres + Redis sidecars) |

## Data mounts

Data files are **mounted automatically** by the benchmark runner — your Dockerfile does not need to include them. The following paths are available inside the container at runtime:

| Path | Description |
|------|-------------|
| `/data/dataset.json` | 50-item dataset for `/json`, `/db`, and `/async-db` |
| `/data/static/` | 20 static assets for `/static/*` (HTML, JS, CSS, SVG, WebP, woff2, JSON). 15 assets ship with pre-built `.gz` and `.br` sibling files (e.g. `app.js`, `app.js.gz`, `app.js.br`) so frameworks that support precompressed serving can skip on-the-fly compression. The 5 already-binary formats (`hero.webp`, `thumb1.webp`, `thumb2.webp`, `bold.woff2`, `regular.woff2`) have no precompressed variants. See the [Static](h1/isolated/static/) profile for how to wire Accept-Encoding lookup. |
| `/certs/server.crt`, `/certs/server.key` | TLS certificate and key for HTTPS / H2 / H2 h2c (port 8082 is cleartext) / H3 |

## Environment variables

Set by the benchmark runner when the relevant profile runs — your process will see them via `os.environ` / `std::env::var` / equivalent.

| Variable | Profiles | Value |
|----------|----------|-------|
| `DATABASE_URL` | `async-db`, `crud`, `api-4`, `api-16` | Postgres connection string (`postgres://bench:bench@127.0.0.1:5432/benchmark`) |
| `DATABASE_MAX_CONN` | same as above | `256` — the Postgres sidecar's `max_connections`; size your pool ≤ this |
| `REDIS_URL` | `crud` | `redis://127.0.0.1:6379` — multi-process frameworks can use Redis as a cross-process cache; single-heap frameworks (Go, ASP.NET, etc.) typically ignore it and keep their in-process cache |

Gateway and `production-stack` profiles are compose-orchestrated, so their services receive additional env (e.g. `JWT_SECRET` for the production-stack auth sidecar) via their `compose.*.yml` files rather than through the runner. See the per-profile pages under [Gateway](gateway/) for details.

{{< cards >}}
  {{< card link="h1" title="H/1.1" subtitle="Isolated single-endpoint benchmarks and multi-endpoint workload mixes over plain TCP." icon="lightning-bolt" >}}
  {{< card link="h2" title="H/2" subtitle="Baseline and static file benchmarks over encrypted TLS connections with stream multiplexing." icon="globe-alt" >}}
  {{< card link="gateway" title="Gateway" subtitle="Multi-service deployments: proxy + server (H2/H3) and full CRUD production stack with JWT auth + cache-aside." icon="server" >}}
  {{< card link="h3" title="H/3" subtitle="Baseline and static file benchmarks over QUIC for frameworks with native H/3 support." icon="globe-alt" >}}
  {{< card link="grpc" title="gRPC" subtitle="Unary RPC throughput over cleartext HTTP/2 using Protocol Buffers serialization." icon="globe-alt" >}}
  {{< card link="ws" title="WebSocket" subtitle="WebSocket echo throughput measuring frame processing performance." icon="globe-alt" >}}
{{< /cards >}}
