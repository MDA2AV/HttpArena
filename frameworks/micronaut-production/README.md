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
