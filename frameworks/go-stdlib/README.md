# go-stdlib

The Go standard library `net/http` server, no framework, default configuration.

## Stack

- **Language:** Go 1.27
- **Framework:** none, `net/http` with the Go 1.22 `ServeMux` patterns
- **HTTP/2:** `net/http` itself, over TLS (ALPN) and cleartext with prior knowledge
- **Build:** `golang:1.27.3-alpine`, static binary on `scratch`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |
| `/baseline2` | GET | Sums query parameter values (h2, h2c) |
| `/static/{filename}` | GET | Files under `/data/static`, pre-compressed twin by `Accept-Encoding` |

## Notes

- Routing and path parameters through `ServeMux`, which since Go 1.22 takes the
  method and a `{count}` wildcard in the pattern, so no router is needed
- JSON serialized by `encoding/json` into a pooled buffer, with `Content-Length` set
- The standard library has no compression middleware, so `/json` gzips its own
  body with `compress/gzip` when `Accept-Encoding` asks for it. This is why the
  entry is `mode: tuned`
- No cluster of processes, the Go runtime already serves every request on its own
  goroutine across all cores. `GOMAXPROCS` is left to the runtime, which since
  Go 1.25 caps it at the container's CPU limit on its own
- Missing dataset file means an empty item list, the server still starts

## Added profiles

`static`, `static-tls`, `json-tls`, `async-db` and `crud`.

- `json-tls` and `static-tls` listen on `8081` when `/certs/server.crt` and `/certs/server.key`
  are mounted; it is the same router behind TLS, not a second copy of the handlers.
- Static file bodies are read from disk on every request, which the static profiles require in
  every mode. The pre-compressed `.br`/`.gz` sibling is picked per request and is also read from disk.
- Postgres goes through `pgx`. One process here, so the whole `DATABASE_MAX_CONN` budget is
  available, less headroom for `superuser_reserved_connections`.
- `crud` runs cache-aside on Redis with a 200ms TTL and an explicit delete on update.
- `tags` is a JSONB column, so it comes back as bytes rather than a Go slice.

## HTTP/2

`baseline-h2`, `static-h2`, `baseline-h2c` and `json-h2c`, all through `net/http` itself.
Every port serves the same `ServeMux`; only the protocol in front of it changes.

| Port | Protocol | How |
|------|----------|-----|
| `8443` | HTTP/2 over TLS, HTTP/1.1 fallback | `http.Server.ListenAndServeTLS`, which negotiates h2 through ALPN on its own |
| `8082` | HTTP/2 cleartext (prior knowledge), HTTP/1.1 | `http.Server.Protocols` with `SetUnencryptedHTTP2(true)` (Go 1.24) |

- `8443` opens only when `/certs` is mounted, like `8081`; `8082` needs no certificate and is always open.
- HTTP/2 runs with net/http's default settings: no stream or window tuning.
