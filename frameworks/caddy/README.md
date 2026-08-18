# caddy

Caddy with two custom Go handler modules (`httparena`, `httparena_json`) compiled into the caddy binary via `xcaddy`. Static files are served by Caddy's native `file_server`.

## Stack

- **Language:** Go
- **Engine:** Caddy v2.8.x
- **Build:** `golang:1.22-bookworm` (xcaddy) -> `debian:bookworm-slim` runtime

## Listeners

| Port | Protocols | Profiles |
|------|-----------|----------|
| 8080 | HTTP/1.1 | baseline, pipelined, limited-conn, json, static |
| 8081 | HTTP/1.1 + TLS | json-tls, static-tls |
| 8443 | h2 (TCP) + h3 (QUIC) | baseline-h2, static-h2, baseline-h3, static-h3 |

All three serve the same routes, defined once as a Caddyfile snippet.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 and HTTP/3 variant) |
| `/json/{count}?m={multiplier}` | GET | Serializes `count` dataset items with `total = price × quantity × m` |
| `/static/{filename}` | GET | Serves static files from `/data/static` |

## Notes

- `httparena/` is a self-contained Go module; `xcaddy build --with <import path>=./httparena` plugs it into the caddy binary at build time.
- `/json` reads `/data/dataset.json` once at provision time and marshals a freshly built response per request — a missing or malformed dataset is a startup error.
- The baseline handler accepts only GET and POST; other methods get `405`.
- Query values that fail to parse as `int64` are skipped (matches nginx/h2o reference behavior).
- `protocols` is set per listener, so 8080 and 8081 stay on HTTP/1.1 and only 8443 negotiates h2/h3.
- `auto_https off`, `admin off`, access log discarded; certificates come from `/certs`, mounted by the harness.
