---
title: Test Profiles
toc: false
---

HttpArena runs every framework through multiple benchmark profiles. Each profile isolates a different performance dimension, ensuring frameworks are compared fairly across varied workloads.

Your framework must implement endpoints depending on which test profiles it participates in. All HTTP/1.1 endpoints are served on **port 8080**. HTTPS/H2/H3 endpoints are served on **port 8443**.

Each profile is run at multiple connection counts to show how frameworks scale under increasing concurrency.

## Benchmark parameters

| Parameter | Value |
|-----------|-------|
| Threads | 12 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Networking | Docker `--network host` |

## Data mounts

Data files are **mounted automatically** by the benchmark runner — your Dockerfile does not need to include them. The following paths are available inside the container at runtime:

| Path | Description |
|------|-------------|
| `/data/dataset.json` | 50-item dataset for `/json` |
| `/data/dataset-large.json` | 6000-item dataset for `/compression` |
| `/data/benchmark.db` | SQLite database (100K rows) for `/db` |
| `/data/static/` | 20 static files for `/static/*` |
| `/certs/server.crt`, `/certs/server.key` | TLS certificate and key for HTTPS/H2/H3 |
| `DATABASE_URL` env var | Postgres connection string for `/pgdb` (set automatically when `async-db` profile runs) |

{{< cards >}}
  {{< card link="h1" title="HTTP/1.1" subtitle="Baseline, short-lived connections, JSON processing, upload, compression, and pipelined benchmarks over plain TCP." icon="lightning-bolt" >}}
  {{< card link="h2" title="HTTP/2" subtitle="Baseline and static file benchmarks over encrypted TLS connections with stream multiplexing." icon="globe-alt" >}}
  {{< card link="h3" title="HTTP/3" subtitle="Baseline and static file benchmarks over QUIC for frameworks with native HTTP/3 support." icon="globe-alt" >}}
  {{< card link="grpc" title="gRPC" subtitle="Unary RPC throughput over cleartext HTTP/2 using Protocol Buffers serialization." icon="globe-alt" >}}
  {{< card link="ws" title="WebSocket" subtitle="WebSocket echo throughput measuring frame processing performance." icon="globe-alt" >}}
{{< /cards >}}
