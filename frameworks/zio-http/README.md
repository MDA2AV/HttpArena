# zio-http

ZIO HTTP on the Netty backend with ZIO 2.

## Stack

- **Language:** Scala 3.3 on Java 21
- **Framework:** ZIO HTTP 3.11 (Netty server, zio-json)
- **Build:** sbt assembly, `eclipse-temurin:21-jre` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Folds over the body stream and returns the byte count |
| `/baseline2` | GET | Sums query parameter values |
| `/async-db` | GET | Reads from PostgreSQL over JDBC on ZIO's blocking pool |
| `/static/:filename` | GET | Serves a file from disk, the brotli or gzip variant when the client accepts one |
| `/crud/items` | GET/POST | Lists items by category with paging, or inserts one |
| `/crud/items/:id` | GET/PUT | Reads one item through a Redis cache-aside, or updates it and drops the cached copy |

## Notes

- Routing and path parameters through the `Routes` DSL
- JSON through zio-json, derived encoders, encoded per request
- Compression through `Server.Config.responseCompression`, the server's own gzip
- Request streaming is hybrid: bodies up to 100 KB are aggregated, larger ones stream, so the 20 MB upload is never buffered
- One JVM process, Netty sizes its event loops from the CPUs the container is allowed to use

`json-tls` and `static-tls` listen on `8081` when `/certs/server.crt` and `/certs/server.key` are
mounted: a second `Server.serve` over the same routes, raced against the plaintext one so a
failure on either port takes the process down rather than leaving a port silently unserved.

Static file bodies are read from disk on every request, per the arena rules; only the content
type is decided from the name.

Postgres is reached over JDBC through HikariCP. The driver blocks, so every query runs on ZIO's
blocking pool and the server's event loops stay free. `DATABASE_URL` arrives as
`postgres://user:pass@host:port/db`, which JDBC does not accept, so it is rewritten to a
`jdbc:postgresql://` URL with the credentials lifted out.
