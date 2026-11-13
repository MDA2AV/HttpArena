# quic-go

[quic-go](https://github.com/quic-go/quic-go)'s HTTP/3 server, default configuration.

## Stack

- **Language:** Go 1.27
- **HTTP/3:** quic-go `http3.Server` on udp/8443
- **Routing:** `net/http` `ServeMux` (Go 1.22 method and wildcard patterns)
- **Build:** `golang:1.27.3-alpine`, static binary on `scratch`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline2` | GET | Sums query parameter values |
| `/static/{filename}` | GET | Files under `/data/static`, pre-compressed twin by `Accept-Encoding` |

## Notes

- `http3.Server` takes an `http.Handler`, so the handlers are plain `net/http` ones
- `/static` reads the file from disk on every request, so a replaced file is served
  with its new bytes immediately; the `.br`/`.gz` twin on disk is chosen off
  `Accept-Encoding`, nothing is compressed at request time
- A `net/http` TLS listener on tcp/8443 serves the same mux so the harness's curl
  readiness probe (which cannot speak QUIC) gets an answer; it is idle during the run

## Profiles

`baseline-h3`, `static-h3`.
