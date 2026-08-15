# slim

Slim 4 on FrankenPHP, classic per-request mode.

## Stack

- **Language:** PHP 8.4
- **Framework:** Slim 4.15 with slim/psr7
- **Server:** FrankenPHP (`dunglas/frankenphp:latest`)

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body stream and returns the byte count |

## Notes

- Routing, path arguments and PSR-7 request/response through the Slim API
- JSON with `json_encode` per request
- Compression through the FrankenPHP (Caddy) `encode br gzip` directive
- No worker mode: one request per process, the way Slim is usually deployed
- `post_max_size=0` so the 20 MB upload profile is not rejected
