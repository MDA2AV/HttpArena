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
| `/baseline2` | GET | Sums query parameter values |
| `/async-db` | GET | Reads from PostgreSQL through the reactive pg client |
| `/static/:filename` | GET | Serves a file from disk with `sendFile`, the brotli or gzip variant when the client accepts one |
| `/crud/items` | GET/POST | Lists items by category with paging, or inserts one |
| `/crud/items/:id` | GET/PUT | Reads one item through a Redis cache-aside, or updates it and drops the cached copy |

## Notes

- Routing, path and query params through the vertx-web `Router`
- JSON built as `JsonObject` and written with `RoutingContext.json`
- Compression through `HttpServerOptions.setCompressionSupported(true)`
- The verticle is deployed once per core, all instances sharing port 8080
- `/upload` is read from the request stream, so the 20 MB body is never buffered

`json-tls` and `static-tls` listen on `8081` when `/certs/server.crt` and `/certs/server.key` are
mounted. The verticle is deployed once per core and each instance binds both ports, so the TLS
listener is spread across every event loop rather than parked on one. ALPN is off: those two
profiles want HTTP/1.1 negotiated and no h2 offered.

Static file bodies are read from disk on every request - `sendFile` hands the descriptor to the
kernel rather than holding the bytes - and the pre-compressed sibling is picked per request.

`tags` is a JSONB column, so the pg client hands back a `JsonArray` rather than text.
