---
title: Implementation Guidelines
---
{{< type-rules production="Must ship exactly two services — one HTTP/3-capable reverse proxy and one application server. The proxy must be a widely-used, production-grade server with QUIC support (Caddy, nginx 1.25+ with ngx_http_v3_module, Envoy, HAProxy 2.8+, h2o). No custom QUIC implementations. No caches, load balancers, or additional sidecars beyond the two services. The proxy must serve /static/* directly from disk; the server must serve /baseline2, /json, and /async-db using standard framework middleware." tuned="Same two-service shape as production. May optimize proxy configuration (worker counts, buffer sizes, keepalive tuning, QUIC parameter tuning). May tune the proxy-to-server protocol (h1/h2c/UDS). Server may use any caching or optimization strategy on its own endpoints." engine="No specific rules. May use custom QUIC implementations. Ranked separately from frameworks." >}}

The Gateway-H3 test is the HTTP/3 sibling of [Gateway-64](../../h2-gateway/gateway-64/). Same endpoint surface, same two-service shape, same 64-CPU budget, same 20-URI round-robin mix — **the only difference is the edge protocol**. The load generator sends requests over QUIC to port 8443 (UDP), the proxy terminates h3 + TLS, and the upstream backend is still reached over plain h1 (or whatever the entry chooses internally).

## Architecture

Exactly two services: one HTTP/3-capable reverse proxy and one application server. The proxy handles QUIC termination and serves `/static/*` directly from disk. The application server handles `/baseline2`, `/json/{count}`, and `/async-db`.

```
                    h3/QUIC (UDP)          proxy → server
  ┌──────────┐    ──────────────>    ┌───────────┐    ──────>    ┌──────────┐
  │ h2load   │                       │   Proxy   │               │  Server  │
  │ (-h3)    │    port 8443/udp      │ h3 + TLS  │    any proto  │  baseline│
  │          │                       │ /static/* │               │  json    │
  └──────────┘                       └───────────┘               │  async-db│
                                                                 └──────────┘
                                     CPU: N of 64                CPU: 64-N
```

## Why split out from Gateway-64?

HTTP/3 shifts work around compared to HTTP/2 in ways that are worth measuring separately:

- **No head-of-line blocking** at the TCP layer — QUIC streams are independent, so a slow response on one stream doesn't stall others on the same connection
- **Stream and datagram framing happens in userspace**, not in the kernel's TCP stack — moves CPU cost from `softirq` to the proxy process
- **Encryption is per-packet, not per-record** — different cost profile than TLS-over-TCP
- **UDP send/recv syscall overhead** is higher than TCP `sendfile()`, but `SO_TXTIME` / `SO_TIMESTAMPING` / GRO/GSO mitigations vary by kernel version and proxy implementation
- **Connection migration and 0-RTT** are h3-specific features that production proxies handle very differently

The H/2 Gateway numbers can't predict any of this. Running the same workload over h3 gives you the other half of the picture.

## Endpoint responsibilities

Same as [Gateway-64](../../h2-gateway/gateway-64/implementation/#endpoint-responsibilities):

| Path | Handled by | Role |
|---|---|---|
| `/static/*` | Proxy | Static files served directly from `/data/static/` (precompressed `.br`/`.gz` sidecars allowed) |
| `/baseline2?a=N&b=M` | Server | Query-parameter sum |
| `/json/{count}` | Server | Dataset processing (~10 KB JSON response) |
| `/async-db?min=N&max=M&limit=L` | Server | Postgres range query |

Rules (identical to Gateway-64):

- The proxy **must** serve `/static/*` from disk. Forwarding static files to the server is not allowed.
- The server **must** serve all three dynamic endpoints. Proxy-level caching of dynamic responses is not allowed.
- The proxy **must** terminate QUIC + TLS at the edge.

## Docker Compose

Entries ship a `compose.gateway-h3.yml` file with exactly two services named `proxy` and `server`. The benchmark script builds, starts, and tears down the stack for each run.

### Example

```yaml
services:
  proxy:
    build: ./proxy
    network_mode: host
    cpuset: "0-19,64-83"
    ulimits:
      memlock: -1
      nofile:
        soft: 1048576
        hard: 1048576
    security_opt:
      - seccomp:unconfined
    volumes:
      - ${CERTS_DIR}:/certs:ro
      - ${DATA_DIR}/static:/data/static:ro
    depends_on:
      - server

  server:
    build:
      context: ../../
      dockerfile: frameworks/my-framework/Dockerfile
    network_mode: host
    cpuset: "20-31,84-95"
    ulimits:
      memlock: -1
      nofile:
        soft: 1048576
        hard: 1048576
    security_opt:
      - seccomp:unconfined
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - DATABASE_MAX_CONN=256
    volumes:
      - ${DATA_DIR}/dataset.json:/data/dataset.json:ro
```

Proxy options (pick one):

- **Caddy** — h3 is enabled by default when you bind a TLS listener. Stock `caddy:2-alpine` image works out of the box. See the reference entry at [`frameworks/aspnet-minimal_caddy/`](https://github.com/MDA2AV/HttpArena/tree/main/frameworks/aspnet-minimal_caddy) for a minimal working Caddyfile.
- **nginx with QUIC** — nginx 1.25+ supports h3 via `ngx_http_v3_module`, but the stock `nginx:alpine` image is not built with it. You need to either build from source or use a community image that includes QUIC.
- **Envoy** — supports h3 via the `envoy.quic.connection_id_generator` + `QuicProtocolOptions` listener config.
- **HAProxy 2.8+** — supports h3 via the `quic4@:8443` bind spec.

### Required compose settings

| Setting | Value | Why |
|---|---|---|
| `network_mode: host` | Both services | Bridge networking adds measurable latency; host networking keeps proxy-to-server at native localhost speed, and lets the proxy bind UDP 8443 directly on the host for QUIC. |
| `cpuset` | CPU range string | Pins the service to specific cores. See [CPU allocation](#cpu-allocation). |
| `security_opt: [seccomp:unconfined]` | Both services | Allows io_uring and other syscalls the default seccomp profile blocks. QUIC-specific syscalls like `SO_TXTIME` also benefit. |
| `ulimits.memlock: -1` | Both services | Allows memory locking for performance-critical operations. |
| `ulimits.nofile: { soft: 1048576, hard: 1048576 }` | Both services | Raises the file descriptor limit. |

## CPU allocation

Identical to [Gateway-64](../../h2-gateway/gateway-64/implementation/#cpu-allocation) — 64 logical CPUs (32 physical + 32 SMT siblings) split freely between proxy and server, with SMT-sibling pairing required. See the Gateway-64 page for the full rules.

## Workload

The load generator (`h2load-h3`) requests 20 URIs in a round-robin across multiplexed HTTP/3 streams. All requests include `Accept-Encoding: br;q=1, gzip;q=0.8`:

| Category | URIs | Count | Weight | Handled by |
|---|---|---|---|---|
| Static files | `/static/reset.css`, `components.css`, `app.js`, `vendor.js`, `header.html`, `hero.webp` | 6 | 30% | Proxy |
| JSON | `/json/{count}` with `count ∈ {1, 5, 10, 15, 25, 40, 50}` | 7 | 35% | Server |
| Baseline | `/baseline2?a=N&b=M` with 4 distinct parameter combinations | 4 | 20% | Server |
| Async DB | `/async-db?min=10&max=50&limit=N` with `limit ∈ {10, 25, 50}` | 3 | 15% | Server |

Same mix and weighting as Gateway-64 — the `requests/gateway-64-uris.txt` URI file is shared between both profiles so benchmark numbers are directly comparable across the edge protocol dimension.

## What it measures

- **QUIC termination cost** at the proxy at realistic connection counts
- **HTTP/3 stream multiplexing** through a proxy
- **Static file serving over h3** — disk I/O + precompressed asset selection + UDP send path
- **Mixed workload throughput** when the edge is QUIC instead of TCP+TLS
- **h3-vs-h2 delta** for the same stack — comparing Gateway-H3 to Gateway-64 numbers tells you how much of a framework's gateway performance is attributable to edge protocol choice

## Parameters

| Parameter | Value |
|---|---|
| Endpoints | `/static/*`, `/json/{count}`, `/async-db`, `/baseline2` |
| Connections | 64, 256 |
| Streams per connection | 32 (`-m 32`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load-h3 with `-i` (multi-URI round-robin) and `--alpn-list=h3` |
| Total CPU budget | 64 logical (32 physical + 32 SMT), split freely between proxy and server |
| Memory limit | Unlimited |
| Port | 8443 (UDP for h3, TCP as fallback for h1/h2 depending on proxy) |
| Orchestration | Docker Compose (`compose.gateway-h3.yml`) |
