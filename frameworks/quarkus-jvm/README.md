# quarkus-jvm

Quarkus with RESTEasy Reactive on Vert.x/Netty, JDK 21, optimized JVM tuning.

## Stack

- **Language:** Java 21
- **Framework:** Quarkus (RESTEasy Reactive)
- **Engine:** Vert.x / Netty
- **Build:** `maven:3.9-eclipse-temurin-21` → `eclipse-temurin:21-jre` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json` | GET | Processes 50-item dataset, serializes JSON |
| `/compression` | GET | Gzip-compressed large JSON response |
| `/db` | GET | SQLite range query with JSON response |
| `/echo` | POST | Returns the request body back verbatim |
| `/static/{filename}` | GET | Serves preloaded static files with MIME types |

## Notes

- `@NonBlocking` reactive execution
- SQLite via JDBC with immutable mode
- JVM tuning: `-XX:+UseParallelGC`, `-XX:+UseNUMA`
- Quarkus metrics, headers, and websocket disabled for minimal overhead
- `ConcurrentHashMap` for static file cache
