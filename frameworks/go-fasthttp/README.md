# go-fasthttp

High-performance Go HTTP server using fasthttp with zero-allocation design and buffer reuse.

## Stack

- **Language:** Go 1.24
- **Framework:** fasthttp
- **Build:** `golang:1.24-alpine` → `alpine:3.19` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json` | GET | Processes 50-item dataset, serializes JSON |
| `/compression` | GET | Gzip-compressed large JSON response |
| `/db` | GET | SQLite range query with JSON response |
| `/upload` | POST | Receives 1 MB body, returns byte count |

## Notes

- One goroutine listener per CPU core via `SO_REUSEPORT`
- `modernc.org/sqlite` for CGO-free database access
- Compression via `compress/flate` (level 1)
- Zero-copy query parameter iteration with `VisitAll`
- Baseline11 is the default route handler

## Added profiles

`static-tls`, `json-tls` and `crud`.

- `json-tls` and `static-tls` listen on `8081` when `/certs/server.crt` and `/certs/server.key`
  are mounted. Every worker binds it the same way they all bind `8080`, so the TLS listener is
  spread across the same set of processes rather than parked on one.
- The static handler no longer uses `fasthttp.FS`. That keeps small files in an in-memory cache
  and writes its own compressed copies next to the originals; the static profiles forbid holding
  file bodies in memory in every mode. Bodies are now read from disk on every request and the
  pre-compressed `.br`/`.gz` sibling is picked per request.
- `crud` runs cache-aside on Redis with a 200ms TTL and an explicit delete on update.
