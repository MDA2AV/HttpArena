# micronaut

Micronaut on the Netty HTTP server, default configuration, on the JVM.

## Stack

- **Language:** Java 25
- **Framework:** Micronaut 5.1 (`micronaut-http-server-netty`)
- **Build:** Maven shade jar, `eclipse-temurin:25-jre` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing and path parameters through the `@Controller` annotations, all resolved
  at compile time by the Micronaut annotation processor, so there is no
  reflection and no classpath scanning at startup
- JSON serialized by Jackson from Java records
- Compression is the Netty server compression that Micronaut turns on by itself,
  over its default 1 KB threshold
- No cluster of processes: the JVM is one process and Netty sizes its event loop
  group from the cores the container is given
- `/upload` binds the body as a `Publisher`, so the 20 MB body is counted while
  it arrives and never buffered
- The dataset is read once at startup from `DATASET_PATH`, `/data/dataset.json`
  by default, and a missing file leaves an empty list instead of failing
