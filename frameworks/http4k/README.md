# http4k

http4k on the Undertow backend, default configuration.

## Stack

- **Language:** Kotlin 2.4 on Java 21
- **Framework:** http4k 6.57
- **Build:** Gradle `installDist`, `eclipse-temurin:21-jre` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing and path/query access through the http4k `routes` DSL
- JSON through the http4k Jackson module, serialized per request
- Compression through `ServerFilters.GZip()`
- `/upload` reads the request stream in chunks, so the 20 MB body is not buffered
