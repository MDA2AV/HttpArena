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

## Notes

- Routing and path parameters through the `Routes` DSL
- JSON through zio-json, derived encoders, encoded per request
- Compression through `Server.Config.responseCompression`, the server's own gzip
- Request streaming is hybrid: bodies up to 100 KB are aggregated, larger ones stream, so the 20 MB upload is never buffered
- One JVM process, Netty sizes its event loops from the CPUs the container is allowed to use
