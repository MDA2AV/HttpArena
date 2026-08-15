# javalin

Javalin on embedded Jetty, default configuration.

## Stack

- **Language:** Java 21
- **Framework:** Javalin 7.2 on Jetty 12
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

- Routing, path and query params through the Javalin router
- JSON written with `ctx.json`, serialized by the Jackson mapper Javalin ships
- Compression through Javalin's own `CompressionStrategy.GZIP`, defaults untouched
- One JVM with the default Jetty thread pool, which sizes itself from the cores the container gets
- `/upload` is counted off the request stream, so the 20 MB body is never buffered
- The dataset is read once at startup from `DATASET_PATH`, defaulting to `/data/dataset.json`
