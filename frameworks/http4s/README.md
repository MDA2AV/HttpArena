# http4s

http4s on the Ember server with cats-effect.

## Stack

- **Language:** Scala 3.3 on Java 21
- **Framework:** http4s 0.23 (ember-server, dsl, circe)
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

- Routing and query matchers through the http4s DSL
- JSON through circe, encoded per request
- Compression through the http4s `GZip` middleware
- `/upload` consumes the fs2 body stream, so the 20 MB body is never buffered
