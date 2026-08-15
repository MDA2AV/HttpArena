# h2o

High-performance C HTTP server using the libh2o library with multi-threaded event loops and native HTTP/2 support. One event loop and one set of listeners per core, all with `SO_REUSEPORT`.

## Stack

- **Language:** C
- **Engine:** h2o (libh2o-evloop)
- **Build:** `buildpack-deps:bookworm` → `debian:bookworm-slim`, clang with `-O3 -march=native`

## Listeners

| Port | Protocols | Profiles |
|------|-----------|----------|
| 8080 | HTTP/1.1 | baseline, pipelined, limited-conn, json, static |
| 8081 | HTTP/1.1 + TLS | json-tls, static-tls |
| 8443 | h2 (TLS, ALPN) | baseline-h2, static-h2 |

No HTTP/3: libh2o's QUIC stack is not wired up in this embedded server, so the h3 profiles are not claimed.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json/{count}?m={multiplier}` | GET | Serializes `count` dataset items with `total = price × quantity × m` |
| `/static/{filename}` | GET | Serves preloaded static files (max 32) |

## Notes

- Custom C handlers registered directly with h2o; no configuration file
- `/data/dataset.json` is parsed once at startup into typed fields, and each response is serialized per request into the request pool
- The dataset's string fields are re-emitted verbatim from the source buffer rather than copied, so escapes round-trip exactly
- A missing or malformed dataset leaves `/json` returning 500 rather than preventing startup, so the other profiles still run
- Static files preloaded at startup with MIME type mapping
- The 8081 TLS context registers no ALPN protocols, so clients stay on HTTP/1.1; 8443 advertises h2
