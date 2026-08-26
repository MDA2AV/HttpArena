# chi

chi router on the Go `net/http` server, default configuration.

## Stack

- **Language:** Go 1.26
- **Framework:** chi v5.3
- **Build:** `golang:1.26-alpine` -> `alpine:3.23` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body and returns the byte count |

## Notes

- Routing and path parameters through the chi router, handlers are plain `http.HandlerFunc`
- JSON through `encoding/json`, chi has no response helper of its own
- Compression through the `chi/v5/middleware.Compress` middleware
- No process forking: `net/http` serves every request on its own goroutine, and
  the Go runtime reads the cgroup CPU limit to size `GOMAXPROCS`

## Added profiles

`static`, `static-tls`, `json-tls`, `async-db` and `crud`.

- `json-tls` and `static-tls` listen on `8081` when `/certs/server.crt` and `/certs/server.key`
  are mounted; it is the same router behind TLS, not a second copy of the handlers.
- Static file bodies are read from disk on every request, which the static profiles require in
  every mode. Standard mode leaves the encoding to the compression middleware rather than
  serving a pre-compressed sibling.
- Postgres goes through `pgx`. One process here, so the whole `DATABASE_MAX_CONN` budget is
  available, less headroom for `superuser_reserved_connections`.
- `crud` runs cache-aside on Redis with a 200ms TTL and an explicit delete on update.
- `tags` is a JSONB column, so it comes back as bytes rather than a Go slice.
