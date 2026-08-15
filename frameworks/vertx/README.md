# vertx

Eclipse Vert.x with vertx-web on Netty, one server verticle per core.

## Stack

- **Language:** Java 21
- **Framework:** Vert.x 5.1 (vertx-core + vertx-web)
- **Build:** Maven shade jar, `eclipse-temurin:21-jre` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing, path and query params through the vertx-web `Router`
- JSON built as `JsonObject` and written with `RoutingContext.json`
- Compression through `HttpServerOptions.setCompressionSupported(true)`
- The verticle is deployed once per core, all instances sharing port 8080
- `/upload` is read from the request stream, so the 20 MB body is never buffered
