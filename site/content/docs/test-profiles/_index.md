---
title: Test Profiles
weight: -1
toc: false
---

HttpArena runs every framework through multiple benchmark profiles. Each profile isolates a different performance dimension, ensuring frameworks are compared fairly across varied workloads.

Your framework must implement endpoints depending on which test profiles it participates in. All HTTP/1.1 endpoints are served on **port 8080**. HTTPS/H2/H3 endpoints are served on **port 8443**.

Each profile is run at multiple connection counts to show how frameworks scale under increasing concurrency.

## Benchmark parameters

| Parameter | Value |
|-----------|-------|
| Threads | 64 (gcannon) / 128 (h2load) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Networking | Docker `--network host` |

## Data mounts

Data files are **mounted automatically** by the benchmark runner — your Dockerfile does not need to include them. The following paths are available inside the container at runtime:

| Path | Description |
|------|-------------|
| `/data/dataset.json` | 50-item dataset for `/json` |
| `/data/static/` | 20 static files for `/static/*` |
| `/certs/server.crt`, `/certs/server.key` | TLS certificate and key for HTTPS/H2/H3 |
| `DATABASE_URL` env var | Postgres connection string for `/async-db` (set automatically when `async-db` profile runs) |

{{< cards >}}
  {{< card link="h1" title="H/1.1" subtitle="Isolated single-endpoint benchmarks and multi-endpoint workload mixes over plain TCP." icon="lightning-bolt" >}}
  {{< card link="h2" title="H/2" subtitle="Baseline and static file benchmarks over encrypted TLS connections with stream multiplexing." icon="globe-alt" >}}
  {{< card link="h2-gateway" title="H/2 Gateway" subtitle="Reverse proxy + application server benchmarks over HTTP/2 with TLS. Tests full-stack deployment performance." icon="server" >}}
  {{< card link="h3" title="H/3" subtitle="Baseline and static file benchmarks over QUIC for frameworks with native H/3 support." icon="globe-alt" >}}
  {{< card link="grpc" title="gRPC" subtitle="Unary RPC throughput over cleartext HTTP/2 using Protocol Buffers serialization." icon="globe-alt" >}}
  {{< card link="ws" title="WebSocket" subtitle="WebSocket echo throughput measuring frame processing performance." icon="globe-alt" >}}
{{< /cards >}}
