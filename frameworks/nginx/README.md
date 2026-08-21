# nginx

Nginx with a custom C handler module (`ngx_http_httparena_module`) compiled with `-O3 -march=native`. Supports HTTP/2 and HTTP/3 via quictls.

## Stack

- **Language:** C
- **Engine:** nginx 1.30.0
- **TLS:** quictls 3.3.0-quic1 (OpenSSL fork for QUIC)
- **Build:** Debian bookworm, compiles nginx + quictls + ngx_brotli from source

## Listeners

| Port | Protocols | Profiles |
|------|-----------|----------|
| 8080 | HTTP/1.1 | baseline, pipelined, limited-conn, json, static |
| 8081 | HTTP/1.1 + TLS | json-tls, static-tls |
| 8443 | h2 (TCP) + h3 (QUIC) | baseline-h2, static-h2, baseline-h3, static-h3 |

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 and HTTP/3 variant) |
| `/json/{count}?m={multiplier}` | GET | Serializes `count` dataset items with `total = price × quantity × m` |
| `/static/{filename}` | GET | Serves static files with MIME types |

## Notes

- Custom C module; JSON is serialized directly into the response buffer, with the dataset parsed from `/data/dataset.json` once per worker at `init_process`
- The dataset's string fields are re-emitted verbatim from the source buffer rather than copied, so escapes round-trip exactly
- A missing or malformed dataset leaves `/json` returning 500 rather than preventing startup, so the other profiles still run
- Worker processes auto-configured to CPU count; 65536 worker connections per process
- Gzip and brotli at server level, plus `gzip_static` / `brotli_static` for pre-compressed assets
