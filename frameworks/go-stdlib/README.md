# go-stdlib

The Go standard library `net/http` server, no framework, default configuration.

## Stack

- **Language:** Go 1.26
- **Framework:** none, `net/http` with the Go 1.22 `ServeMux` patterns
- **Build:** `golang:1.26-alpine`, static binary on `scratch`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing and path parameters through `ServeMux`, which since Go 1.22 takes the
  method and a `{count}` wildcard in the pattern, so no router is needed
- JSON serialized by `encoding/json` into a pooled buffer, with `Content-Length` set
- The standard library has no compression middleware, so `/json` gzips its own
  body with `compress/gzip` when `Accept-Encoding` asks for it. This is why the
  entry is `mode: tuned`
- No cluster of processes, the Go runtime already serves every request on its own
  goroutine across all cores. `GOMAXPROCS` is capped by the cgroup cpu quota when
  there is one
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
