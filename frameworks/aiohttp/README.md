# aiohttp

aiohttp on its own asyncio HTTP server, default configuration.

## Stack

- **Language:** Python 3.13
- **Framework:** aiohttp 3.14
- **Loop:** uvloop 0.22
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

- Routing and path parameters through the aiohttp router
- JSON serialized per request by `web.json_response`
- Compression through the built-in `Response.enable_compression()`, which reads Accept-Encoding
- One forked worker per available core, each with its own event loop and an
  SO_REUSEPORT listener, because an aiohttp server runs on a single thread
- The core count comes from the cgroup CPU quota, with the affinity mask as fallback
- Access log off and `client_max_size` raised to 64 MB so the upload profile is not rejected
