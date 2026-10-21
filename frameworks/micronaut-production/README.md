# micronaut-production

Micronaut 5.2 on the Netty HTTP server, default configuration, on the JVM. Standard mode.

## Stack

- **Language:** Java 27
- **Framework:** Micronaut 5.2 (`micronaut-http-server-netty`, platform 5.2.3)
- **JSON:** Micronaut Serialization (`micronaut-serde-jackson`)
- **Build:** Maven shade jar, `eclipse-temurin:27-jre` runtime

Query parameters are bound with `@QueryValue`, request bodies with `@Body`, and the response bodies are returned from the controller methods, so routing, request binding and response building are all done by the framework. No server settings are changed.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums the `a` and `b` query parameters |
| `/baseline11` | POST | Sums the query parameters and the request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |
| `/baseline2?a=1&b=1` | GET | Sums the query parameters, used by the HTTP/2 profiles |
| `/delay/{ms}` | GET | Answers after `ms` milliseconds without holding a request thread |
| `/static/{name}` | GET | Files from `/data/static`; a `.br` or `.gz` twin is sent as is when the client accepts it |
| `/ws` | WebSocket | Echoes every text and binary frame |

## Ports

| Port | Protocol |
|------|----------|
| 8080 | HTTP/1.1 and cleartext HTTP/2 upgrade |
| 8081 | HTTP/1.1 over TLS |
| 8082 | Cleartext HTTP/2 (prior knowledge) |
| 8443 | HTTP/2 over TLS |

HTTP/2 is switched on for the whole server (`micronaut.server.http-version=2.0`), TLS key material comes from `/certs/server.crt` and `/certs/server.key`.
