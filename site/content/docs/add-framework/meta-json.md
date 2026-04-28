---
title: meta.json
---

Create a `meta.json` file in your framework directory:

```json
{
  "display_name": "your-framework",
  "language": "Go",
  "engine": "net/http",
  "type": "production",
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
| `json` | HTTP/1.1 | `/json/{count}?m=N` |
| `json-comp` | HTTP/1.1 | `/json/{count}?m=N` (must honor `Accept-Encoding: gzip, br`) |
| `json-tls` | HTTP/1.1 + TLS | `/json/{count}?m=N` (port 8081, ALPN `http/1.1`) |
| `upload` | HTTP/1.1 | `/upload` |
| `api-4` | HTTP/1.1 | `/baseline11`, `/json/{count}`, `/async-db` (4 CPU, 16 GB) |
| `api-16` | HTTP/1.1 | `/baseline11`, `/json/{count}`, `/async-db` (16 CPU, 32 GB) |
| `static` | HTTP/1.1 | `/static/*` (port 8080) |
| `async-db` | HTTP/1.1 | `/async-db?min=X&max=Y&limit=N` (requires `DATABASE_URL`) |
| `crud` | HTTP/1.1 | `/api/items`, `/api/items/{id}` (GET/POST/PUT; requires `DATABASE_URL`, optional `REDIS_URL`) |
| `baseline-h2` | HTTP/2 | `/baseline2` (TLS, port 8443) |
| `static-h2` | HTTP/2 | `/static/*` (TLS, port 8443) |
| `baseline-h2c` | HTTP/2 cleartext | `/baseline2` (port 8082, prior-knowledge) |
| `json-h2c` | HTTP/2 cleartext | `/json/{count}?m=N` (port 8082, prior-knowledge) |
| `baseline-h3` | HTTP/3 | `/baseline2` (QUIC, port 8443) |
| `static-h3` | HTTP/3 | `/static/*` (QUIC, port 8443) |
| `gateway-64` | HTTP/2 | Compose stack serving `/static/*`, `/json`, `/async-db`, `/baseline2` (TLS, port 8443) |
| `gateway-h3` | HTTP/3 | Compose stack serving `/static/*`, `/json`, `/async-db`, `/baseline2` (QUIC, port 8443) |
| `production-stack` | HTTP/2 | Compose stack: edge + JWT auth sidecar + Redis + server (TLS, port 8443) |
| `unary-grpc` | gRPC | `BenchmarkService/GetSum` (h2c, port 8080) |
| `unary-grpc-tls` | gRPC | `BenchmarkService/GetSum` (TLS, port 8443) |
| `stream-grpc` | gRPC | `BenchmarkService/StreamSum` (h2c, port 8080) |
| `stream-grpc-tls` | gRPC | `BenchmarkService/StreamSum` (TLS, port 8443) |
| `echo-ws` | WebSocket | `/ws` echo (port 8080) |

Only include profiles your framework supports. Frameworks missing a profile simply don't appear in that profile's leaderboard.

Per-profile endpoint contracts, request/response shapes, and validation rules live under the [Test Profiles](/docs/test-profiles/) section — link to the specific profile's Implementation page from your PR description when adding a new framework.
