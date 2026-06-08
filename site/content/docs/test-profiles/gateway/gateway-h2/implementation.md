---
title: Implementation Guidelines
---
{{< type-rules production="Must ship exactly two services - one reverse proxy and one application server. The proxy must be a widely-used, production-grade server (Nginx, Caddy, Envoy, HAProxy, Traefik, etc.). No custom proxy implementations. No caches, load balancers, or additional sidecars beyond the two services. The proxy must serve /static/* directly from disk; the server must serve /baseline2, /json, and /async-db using standard framework middleware." tuned="Same two-service shape as production. May optimize proxy configuration (worker counts, buffer sizes, keepalive tuning, connection pooling). May tune the proxy-to-server protocol (h2c, Unix sockets, etc.). Server may use any caching or optimization strategy on its own endpoints." engine="No specific rules. May use custom proxy implementations. Ranked separately from frameworks." >}}

The Gateway-64 test benchmarks a **proxy + server combination** as a unit. The load generator sends TLS-encrypted HTTP/2 requests to port 8443; the proxy terminates TLS, serves `/static/*` directly from disk, and forwards dynamic endpoints to the application server over the entry's choice of internal protocol.

## Architecture

Exactly two services - nothing else. One proxy, one server. Splitting dynamic endpoints across multiple servers, adding a caching layer, load-balancing across replicas, or running a single combined service are all **not allowed** for this test. The shape is fixed so entries compete on proxy choice, proxy tuning, proxy-to-server protocol, and CPU split - not on architectural creativity.

```
                    TLS (h2)              proxy → server
  ┌──────────┐    ──────────>    ┌───────────┐    ──────>    ┌──────────┐
  │  h2load  │                   │   Proxy   │               │  Server  │
  │  (load   │    port 8443      │ TLS term  │    any proto  │  baseline│
  │   gen)   │    HTTPS/h2       │ /static/* │               │  json    │
  └──────────┘                   └───────────┘               │  async-db│
                                                             └──────────┘
                                 CPU: N of 64                CPU: 64-N
```

## Endpoint responsibilities

| Path | Handled by | Role |
|---|---|---|
| `/static/*` | Proxy | Static files served directly from `/data/static/` |
| `/baseline2?a=N&b=M` | Server | Query-parameter sum |
| `/json` | Server | Dataset processing (~10 KB JSON response) |
| `/async-db?min=N&max=M` | Server | Postgres range query |

Rules:

- The proxy **must** serve `/static/*` from disk. Forwarding static files to the server is not allowed.
- The server **must** serve all three dynamic endpoints. Proxy-level caching of dynamic responses is not allowed.
- The proxy **must** terminate TLS. Passing raw TLS through to the server is not allowed.

See the individual test profile docs for each endpoint's exact request/response format:

- [`/static/*`](/docs/test-profiles/h1/isolated/static/implementation/)
- [`/baseline2`](/docs/test-profiles/h2/baseline-h2/implementation/)
- [`/json`](/docs/test-profiles/h1/isolated/json-processing/implementation/)
- [`/async-db`](/docs/test-profiles/h1/isolated/async-database/implementation/)

## Docker Compose

Every gateway entry is orchestrated via a `compose.gateway.yml` file with exactly two services named `proxy` and `server`. The benchmark script builds, starts, and tears down the stack for each run.

### Example

```yaml
services:
  proxy:
    build: ./proxy
    network_mode: host
    cpuset: "0-7,64-71"
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
    cpuset: "8-31,72-95"
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

In this split:

- **Proxy** (Nginx) gets 8 physical cores (16 logical: `0-7,64-71`) - terminates TLS, serves `/static/*` directly from `/data/static/`, forwards dynamic endpoints to the server on localhost.
- **Server** gets 24 physical cores (48 logical: `8-31,72-95`) - listens on an internal port (e.g. `8080` plain HTTP/1.1 or h2c) and handles `/baseline2`, `/json`, `/async-db`.

Total: 16 + 48 = 64 logical CPUs.

### Environment variables

The benchmark script exports three environment variables before every compose command. Your compose file **must** use these - do not hardcode paths.

| Variable | Value |
|---|---|
| `CERTS_DIR` | Absolute path to the TLS certificate directory (`server.crt`, `server.key`) |
| `DATA_DIR` | Absolute path to the data directory (`static/`, `dataset.json`) |
| `DATABASE_URL` | Postgres connection string for `/async-db` (sidecar is started by the benchmark script) |

### Required compose settings

Every service in your compose file **must** include these settings:

| Setting | Value | Why |
|---|---|---|
| `network_mode: host` | Both services | Bridge networking adds measurable latency; host networking keeps proxy-to-server at native localhost speed. |
| `cpuset` | CPU range string | Pins the service to specific cores. See [CPU allocation](#cpu-allocation). |
| `security_opt: [seccomp:unconfined]` | Both services | Allows io_uring and other syscalls that the default seccomp profile blocks. |
| `ulimits.memlock: -1` | Both services | Allows memory locking for performance-critical operations. |
| `ulimits.nofile: { soft: 1048576, hard: 1048576 }` | Both services | Raises the file descriptor limit. |

## Proxy → server protocol

The proxy-to-server transport is the entry's choice and one of the most important tuning decisions:

| Protocol | Pros | Cons |
|---|---|---|
| **HTTP/1.1 over TCP** | Simplest to configure, universally supported | No multiplexing - one request per connection at a time |
| **HTTP/1.1 + keepalive pool** | Reuses connections, avoids handshake per request | Still no multiplexing |
| **h2c (HTTP/2 cleartext)** | Multiplexing without the TLS cost of a second hop | Not all frameworks support h2c |
| **Unix domain sockets** | Lowest latency, no TCP stack overhead | Server must listen on a UDS |

The benchmark measures end-to-end throughput from the load generator's perspective. How the proxy talks to the server is an implementation detail, but it materially affects the score.

## CPU allocation

The test uses **64 logical CPUs** - 32 physical cores (0–31) plus their SMT siblings (64–95). The entry's `compose.gateway.yml` defines how these are split between proxy and server using the `cpuset` directive. The split is the entry's choice - give the proxy as little or as much as you want, as long as the total across both services equals exactly 64 logical CPUs.

### CPU topology rules

CPUs are allocated in **physical core pairs** - each allocation includes both the physical core and its SMT sibling. This avoids two services sharing a physical core and ensures consistent per-service performance.

| Proxy cpuset | Server cpuset | Split |
|---|---|---|
| `0-1,64-65` | `2-31,66-95` | 4 + 60 = 64 |
| `0-3,64-67` | `4-31,68-95` | 8 + 56 = 64 |
| `0-7,64-71` | `8-31,72-95` | 16 + 48 = 64 |
| `0-15,64-79` | `16-31,80-95` | 32 + 32 = 64 |

### Understanding SMT pairing

Each physical core has two logical CPUs: the core itself and its SMT (HyperThreading) sibling. On the benchmark machine, physical core **N** maps to logical CPUs **N** and **N+64**:

- Physical core 0 → logical CPUs **0** and **64**
- Physical core 15 → logical CPUs **15** and **79**
- Physical core 31 → logical CPUs **31** and **95**

When you allocate cores, you must always allocate **both siblings** to the same service. Two threads sharing a physical core compete for ALU, cache, and branch predictor - splitting siblings across services causes unpredictable cross-service interference.

**Correct** - proxy gets physical cores 0–7 (16 logical CPUs):
```
cpuset: "0-7,64-71"
```

**Incorrect** - splits a physical core across services:
```
proxy:  cpuset: "0-3"         # gets core 3 without its sibling (67)
server: cpuset: "4-31,64-95"  # gets sibling 67 without core 3
```

**Incorrect** - doesn't allocate all 64 CPUs:
```
proxy:  cpuset: "0-3,64-67"     # 8 CPUs
server: cpuset: "4-15,68-79"    # 24 CPUs - 32 CPUs wasted
```

### Choosing the split

- **Lightweight proxy** (plain forwarding, little static traffic) - 2–4 physical cores is usually enough
- **TLS-terminating proxy with heavy static** - 4–8 physical cores. TLS handshakes and static I/O compete for CPU at high connection counts.
- **Even split** - 16+16 physical cores is a good starting point if you don't know which side is the bottleneck

## meta.json

```json
{
  "display_name": "my-framework + nginx",
  "language": "C#",
  "type": "flagship",
  "mode": "standard",
  "engine": "kestrel",
  "description": "ASP.NET minimal API behind Nginx reverse proxy.",
  "repo": "https://github.com/dotnet/aspnetcore",
  "tests": ["gateway-64"]
}
```

The `tests` array only needs `gateway-64` for gateway-only entries. Frameworks that also participate in other tests can subscribe to both - the standard `Dockerfile` is used for non-gateway tests and `compose.gateway.yml` for `gateway-64`.

## Directory structure

```
frameworks/my-framework/
  compose.gateway.yml   # Two services: proxy + server
  Dockerfile            # Server image
  meta.json
  proxy/
    Dockerfile          # Proxy image (e.g. Nginx with custom config)
    nginx.conf          # Proxy configuration
```

## Workload

The load generator ([h2load](https://nghttp2.org/documentation/h2load-howto.html)) requests 20 URIs in a round-robin across multiplexed HTTP/2 streams, all requests sent with `Accept-Encoding: br;q=1, gzip;q=0.8`:

| Category | URIs | Count | Weight | Handled by |
|---|---|---|---|---|
| Static files | `/static/reset.css`, `components.css`, `app.js`, `vendor.js`, `header.html`, `hero.webp` - a mix of CSS, JS, HTML, and an image for `sendfile`-path coverage | 6 | 30% | Proxy |
| JSON | `/json/{count}` with `count ∈ {1, 5, 10, 15, 25, 40, 50}` - 7 payload sizes, same set as the h1-isolated JSON profile | 7 | 35% | Server |
| Baseline | `/baseline2?a=N&b=M` with 4 distinct parameter combinations to defeat URI-keyed caches | 4 | 20% | Server |
| Async DB | `/async-db?min=10&max=50&limit=N` with `limit ∈ {10, 25, 50}` | 3 | 15% | Server |

The mix is JSON-weighted (35%) because server-side compute is the most expensive part of the stack; static serving (30%) keeps the proxy's I/O path under meaningful load; baseline (20%) measures raw forwarding efficiency at minimal server cost; async-db (15%) is the smallest slice because it's latency-bound on the Postgres round-trip rather than CPU-bound on either service.

The leaderboard shows a colored breakdown of how many requests each category handled.

## What it measures

- **Reverse proxy overhead** - how much throughput is lost by adding a proxy layer vs. direct server access
- **TLS termination efficiency** - the proxy's cost to terminate HTTPS/h2 at high connection counts
- **HTTP/2 multiplexing through a proxy** - whether the proxy can efficiently forward multiplexed streams
- **Static file serving from the proxy** - disk I/O, precompressed asset selection, kernel `sendfile` usage
- **Mixed workload throughput** - static I/O (proxy) vs. compute (server JSON) vs. database (server async-db) all competing for the same 64-CPU budget
- **Proxy-to-server protocol choice** - HTTP/1.1, h2c, or Unix domain sockets
- **CPU split** - how the entry balances proxy and server workload on a fixed CPU budget

## Parameters

| Parameter | Value |
|---|---|
| Endpoints | `/static/*`, `/json`, `/async-db`, `/baseline2` |
| Connections | 512, 1,024 |
| Streams per connection | 32 (`-m 32`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load with `-i` (multi-URI round-robin) |
| Total CPU budget | 64 logical (32 physical + 32 SMT), split freely between proxy and server |
| Memory limit | Unlimited |
| Port | 8443 (HTTPS/H2) |
| Orchestration | Docker Compose (`compose.gateway.yml`) |
