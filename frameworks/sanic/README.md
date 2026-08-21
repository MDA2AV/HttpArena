# sanic

Sanic on its own worker manager, default configuration.

## Stack

- **Language:** Python 3.13
- **Framework:** Sanic 25.3
- **Server:** Sanic's own server, uvloop and httptools
- **Build:** `python:3.13-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing and the `<count:int>` path parameter through the Sanic router
- JSON serialized by the Sanic `json` response, which uses ujson
- Sanic has no compression middleware, so gzip is done by hand in an
  `on_response` middleware: only when the client sends `Accept-Encoding: gzip`,
  and only above 1 KB. That is why the entry is declared `tuned`
- The upload route is `stream=True`, so a 20 MB body is counted chunk by chunk
  and never buffered
- One worker process per available core, started by Sanic's own worker manager,
  not gunicorn. The core count reads the cgroup `cpu.max` quota first, like
  koa's `getCPUCount`, and falls back to the CPU affinity mask
- A missing dataset file leaves the item list empty instead of failing to start
