# micronaut-production

Micronaut on the Netty HTTP server, default configuration, on the JVM. Standard mode.

## Stack

- **Language:** Java 27
- **Framework:** Micronaut (`micronaut-http-server-netty`)
- **JSON:** Micronaut Serialization (`micronaut-serde-jackson`)
- **Views:** Micronaut Views Rocker (`micronaut-views-rocker`)
- **Build:** Maven shade jar, `eclipse-temurin:27-jre` runtime

Query parameters are bound with `@QueryValue`, request bodies with `@Body`, and the response bodies are returned from the controller methods, so routing, request binding and response building are all done by the framework. No server settings are changed.

Dataset loading, PostgreSQL JSON tags and JSON responses use Micronaut Serialization. The database query selects tags as text so the driver does not decode JSONB with its own codec. Jackson Databind is excluded; Jackson Core remains the streaming backend for Micronaut Serialization.

Rocker's documented [`plainTextStrategy=STATIC_STRINGS` build option](https://github.com/fizzed/rocker#integrate-parsergenerator-in-build-tool) matches Micronaut Views' character writer: static template text stays as strings instead of being decoded from byte arrays on every render. HTML escaping and per-request rendering remain enabled.

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
| `/async-db?min=10&max=50&limit=20` | GET | Async PostgreSQL range query; limits are clamped to 1–50 |
| `/fortunes` | GET | Queries and sorts the rows, then returns a `RockerWritable` so Micronaut Views renders the precompiled, HTML-escaping template |

## Ports

| Port | Protocol |
|------|----------|
| 8080 | HTTP/1.1 and cleartext HTTP/2 upgrade |
| 8081 | HTTP/1.1 over TLS |
| 8082 | Cleartext HTTP/2 (prior knowledge) |
| 8443 | HTTP/2 over TLS |
| 8443/UDP | HTTP/3 over QUIC |

HTTP/2 is switched on for the whole server (`micronaut.server.http-version=2.0`), TLS key material comes from `/certs/server.crt` and `/certs/server.key`.

Run `mvn verify` on JDK 27 for the serialization and template-output checks. The Docker build runs these tests too; the repository's `scripts/validate.sh micronaut-production` covers the HTTP contracts against PostgreSQL.
