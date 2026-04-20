# caddy

Caddy with a custom Go handler module (`httparena`) compiled into the caddy binary via `xcaddy`. Static files are served by Caddy's native `file_server`.

## Stack

- **Language:** Go
- **Engine:** Caddy v2.8.x
- **Build:** `golang:1.22-bookworm` (xcaddy) -> `debian:bookworm-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/static/{filename}` | GET | Serves static files from `/data/static` |

## Notes

- `httparena/` is a self-contained Go module; `xcaddy build --with <import path>=./httparena` plugs it into the caddy binary at build time.
- The handler accepts only GET and POST; other methods get `405`.
- Query values that fail to parse as `int64` are skipped (matches nginx/h2o reference behavior).
- HTTP/1.1 on port 8080. No TLS, no HTTP/3.
- `auto_https off`, `admin off`, access log discarded.
