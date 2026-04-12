---
title: meta.json
---

Create a `meta.json` file in your framework directory:

```json
{
  "display_name": "your-framework",
  "language": "Go",
  "engine": "net/http",
  "type": "framework",
  "description": "Short description of the framework and its key features.",
  "repo": "https://github.com/org/repo",
  "enabled": true,
  "tests": ["baseline", "pipelined", "limited-conn", "json", "json-comp", "upload", "api-4", "api-16", "baseline-h2", "static-h2"],
  "maintainers": ["your-github-username"]
}
```

## Fields

| Field | Description |
|-------|-------------|
| `display_name` | Name shown on the leaderboard |
| `language` | Programming language (e.g., `Go`, `Rust`, `C#`, `Java`) |
| `engine` | HTTP server engine (e.g., `Kestrel`, `Tomcat`, `hyper`) |
| `type` | `production` for standard framework usage, `tuned` for optimized/non-default configurations, `engine` for bare-metal implementations |
| `description` | Shown in the framework detail popup on the leaderboard |
| `repo` | Link to the framework's source repository |
| `enabled` | Set to `false` to skip this framework during benchmark runs |
| `tests` | Array of test profiles this framework participates in |
| `maintainers` | Array of GitHub usernames to notify when a PR modifies this framework |

## Available test profiles

| Profile | Protocol | Required endpoints |
|---------|----------|--------------------|
| `baseline` | HTTP/1.1 | `/baseline11` |
| `pipelined` | HTTP/1.1 | `/pipeline` |
| `limited-conn` | HTTP/1.1 | `/baseline11` |
| `json` | HTTP/1.1 | `/json/{count}` |
| `json-comp` | HTTP/1.1 | `/json/{count}?m=N` (must honor `Accept-Encoding: gzip, br`) |
| `upload` | HTTP/1.1 | `/upload` |
| `static` | HTTP/1.1 | `/static/*` (port 8080) |
| `async-db` | HTTP/1.1 | `/async-db?limit=N` (requires `DATABASE_URL` env var) |
| `api-4` | HTTP/1.1 | `/baseline11`, `/json/{count}`, `/async-db` (4 CPU, 16 GB) |
| `api-16` | HTTP/1.1 | `/baseline11`, `/json/{count}`, `/async-db` (16 CPU, 32 GB) |
| `baseline-h2` | HTTP/2 | `/baseline2` (TLS, port 8443) |
| `static-h2` | HTTP/2 | `/static/*` (TLS, port 8443) |
| `gateway-64` | HTTP/2 | `/static/*`, `/json`, `/async-db` via reverse proxy (TLS, port 8443) |
| `baseline-h3` | HTTP/3 | `/baseline2` (QUIC, port 8443) |
| `static-h3` | HTTP/3 | `/static/*` (QUIC, port 8443) |
| `unary-grpc` | gRPC | `BenchmarkService/GetSum` (h2c, port 8080) |
| `unary-grpc-tls` | gRPC | `BenchmarkService/GetSum` (TLS, port 8443) |
| `echo-ws` | WebSocket | `/ws` echo (port 8080) |

Only include profiles your framework supports. Frameworks missing a profile simply don't appear in that profile's leaderboard.

### async-db

The `async-db` profile requires an async PostgreSQL driver. The benchmark script starts a Postgres sidecar with 100K rows and passes `DATABASE_URL=postgres://bench:bench@localhost:5432/benchmark` to your container. Your framework must:

1. Connect to Postgres using the `DATABASE_URL` environment variable
2. Implement `GET /async-db?min=X&max=Y&limit=N` that queries: `SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3`
3. Return JSON: `{"items": [...], "count": N}` with nested `rating: {score, count}` and `tags` as a JSON array
4. Return `{"items":[],"count":0}` if the database is unavailable
5. Use lazy connection initialization — retry connecting if Postgres isn't ready at startup

### gateway-64

The `gateway-64` profile tests your framework as part of a complete deployment stack over HTTP/2 with TLS. Unlike other tests that run a single container, this test uses **Docker Compose** to orchestrate multi-container deployments — typically a reverse proxy in front of an application server, but any architecture is allowed.

**Quick start:**

1. Create a `compose.gateway.yml` in your framework directory
2. Define your services (proxy, server, cache — whatever you need)
3. Pin each service to specific CPUs using `cpuset` — total must be exactly 64 logical CPUs (0-31 + 64-95), always in physical+SMT pairs (core N and N+64 together)
4. All services must use `network_mode: host`, `security_opt: [seccomp:unconfined]`, and appropriate ulimits
5. Use `${CERTS_DIR}`, `${DATA_DIR}`, and `${DATABASE_URL}` env vars — they are exported by the benchmark script
6. Port **8443** must serve HTTPS/H2 — this is where the load generator sends requests
7. The stack must implement `/static/*`, `/json`, `/async-db`, and `/baseline2` endpoints

**What makes this different from other tests:**
- You control the full architecture via Docker Compose
- Multiple containers compete for a shared 64-CPU budget
- The proxy, caching layer, and internal protocol choices are all part of the benchmark
- Static files can be served directly by the proxy (e.g., Nginx) instead of the application server

See the [Gateway-64 implementation guide](/docs/test-profiles/h2-gateway/gateway-64/implementation) for detailed documentation, three complete compose examples (two-tier, three-tier, and single-tier), CPU topology rules, and proxy configuration options.
