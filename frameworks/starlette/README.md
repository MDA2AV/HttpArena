# starlette

Starlette on uvicorn, default configuration, one worker per core.

## Stack

- **Language:** Python 3.13
- **Framework:** Starlette 1.6
- **Server:** uvicorn 0.40 with uvloop
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

- Routing and path parameters through `starlette.routing.Route`
- JSON serialized by `JSONResponse`
- Compression through the stock `GZipMiddleware`, so json-comp measures Starlette's own middleware
- One uvicorn worker per available core, cgroup quota first and CPU affinity after
- Same uvicorn flags as the `fastapi` entry, which runs on this same Starlette version, so the
  two entries differ only by the FastAPI layer
