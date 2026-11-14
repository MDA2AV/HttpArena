# valk

[Valk](https://valk-lang.dev)'s standard library HTTP/1.1, HTTP/2, and WebSocket server (`valk.http` on `valk.net` / `valk.io`, OpenSSL for TLS) in default configuration.

## Stack

- **Language:** Valk 0.8.7
- **Framework:** standard library (`valk.http`, `valk.json`, `valk.fs`, `valk.time`)
- **Build:** official Valk 0.8.7 release tarball on `ubuntu:24.04`, compiled with `valk build src -o /server --release --static`

## Listeners & Endpoints

| Port | Protocol | Endpoints |
|------|----------|-----------|
| `8080` | HTTP/1.1 & WebSocket | `GET/POST /baseline11`, `GET /pipeline`, `GET /delay/@ms`, `GET /json/@count`, `GET /ws` |
| `8081` | HTTP/1.1 + TLS | `GET /json/@count`, `POST /echo`, `GET /static/*` |
| `8082` | HTTP/2 cleartext (h2c) | `GET/POST /baseline2`, `GET /json/@count` |
| `8443` | HTTP/2 + TLS | `GET/POST /baseline2`, `GET /static/*` |

## Notes

- **Routing:** `http.Router` with method and `@param` pattern matching (`route.param`)
- **Middleware:** `http.Server.add_middleware` composable request/response pipeline
- **Request:** parsed `http.Request` exposing method, path, query parameters, headers, and buffered or streamed body
- **Response:** declarative `http.Response` (`text`, `json_of`, custom body/content-type), built-in per-request gzip compression (`server.compress = true`), and `server.add_static_dir` (tracks disk mtime/size and serves pre-compressed `.br` / `.gz` sidecars when available)
- **Event loop:** per-worker `io_uring` event loop with automatic `epoll` fallback when `io_uring` is unavailable, sharing ports via `SO_REUSEPORT` (`server.reuse_port = true`) with one worker per logical CPU
