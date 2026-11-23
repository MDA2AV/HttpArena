# okena

[okena](https://github.com/Lu4nScr1pt1ng/okena) is a load balancer, reverse
proxy and API gateway written in x86-64 assembly: one static binary, no libc,
io_uring (epoll where it is blocked), its own TLS 1.3 and 1.2, HTTP/2 and
HTTP/3.

The endpoints that need code are answered by a handler module,
[`httparena.inc`](httparena.inc), assembled into okena at build time
(`make MODULES=httparena.inc`) the way nginx compiles a module in: it runs in
okena's workers, in their event loop, not in a process behind them. Static
files come from okena's own file server.

## Stack

- **Language:** x86-64 assembly (fasm2)
- **Engine:** okena, pinned to a commit in the Dockerfile
- **TLS:** okena's own TLS 1.3 / 1.2 (AES-GCM, ChaCha20-Poly1305; RSA and ECDSA certificates)
- **Build:** `debian:trixie-slim` (make, the pinned fasm2 assembler okena's Makefile fetches) -> `scratch` runtime

## Listeners

| Port | Protocols | Profiles |
|------|-----------|----------|
| 8080 | HTTP/1.1 | baseline, pipelined, limited-conn, latency-10k, latency-1m, latency-500k-8cpu, async, json-comp |
| 8081 | HTTP/1.1 + TLS (ALPN `http/1.1`) | json-tls, static-tls, 8gbit |
| 8082 | h2c (prior knowledge) | baseline-h2c, json-h2c |
| 8443 | h2 (TCP) + h3 (QUIC) | baseline-h2, static-h2, baseline-h3, static-h3 |

## Endpoints

| Endpoint | Answered by |
|----------|-------------|
| `/baseline11`, `/baseline2` | `handler baseline`: the sum of the query's integer values and, for a POST, of the body's integer (Content-Length or chunked; okena reads the body whole first) |
| `/json/{count}?m=N` | `handler json`: the first `count` items of `/data/dataset.json` (parsed once at start), each with `total = price * quantity * m`, written field by field for every request. On :8080 the route has `compress gzip br`, so okena compresses each answer as the client's `Accept-Encoding` asks (json-comp) |
| `POST /echo` | `handler echo`: the body okena read (Content-Length or chunked, decoded), returned from where it lies |
| `/delay/{ms}` | `handler delay`: the request is held `ms` milliseconds on okena's timers, the worker serving others meanwhile, then answered with `ms` (`0` at once) |
| `/spec`, `/spec/headers` | `handler spec`: the compliance route on :8080, :8082 and :8443 (GET/HEAD text, OPTIONS with `Allow`, POST echo, the request's fields) |
| `/pipeline` | `respond 200 "ok"` (one answer per request) |
| `/static/*` | `files /data precompressed=br,gz`: okena's file server, files opened per request (so a changed file is served at once), the `.br` / `.gz` on disk chosen by `Accept-Encoding` |

The configuration is [`okena.conf`](okena.conf).
