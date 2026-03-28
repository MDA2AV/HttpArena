# libreactor

[libreactor](https://github.com/fredrikwidlund/libreactor) is a high-performance C event-driven library built around epoll with zero-copy patterns and picohttpparser for HTTP parsing. One of the top performers on TechEmpower benchmarks.

## Implementation

- **Engine entry** — raw C HTTP handling, no framework abstractions
- **Event loop**: epoll via libreactor's reactor core
- **HTTP parsing**: picohttpparser (bundled in libreactor)
- **Compiler flags**: `-O3 -march=native -flto`

## Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/baseline11` | GET | Sum query params `a` + `b` |
| `/baseline11` | POST | Sum query params `a` + `b` + body (Content-Length or chunked) |
| `/pipeline` | GET | Returns `ok` as `text/plain` |

## Build

```bash
docker build -t httparena-libreactor frameworks/libreactor
docker run -p 8080:8080 httparena-libreactor
```
