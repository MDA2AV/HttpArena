# Proxygen

This engine entry uses [Meta's Proxygen](https://github.com/facebook/proxygen)
for every advertised protocol:

- Proxygen `HTTPServer` listens on TCP port 8080 for HTTP/1.1 and RFC 6455
  WebSocket upgrades, on TCP port 8081 for HTTP/1.1 over TLS (ALPN
  `http/1.1` only), on TCP port 8082 for prior-knowledge h2c, and with
  TLS/ALPN `h2` on TCP port 8443.
- Proxygen's mvfst-backed `HQServer` listens with ALPN `h3` on UDP port 8443.

Both server APIs run in one process. TCP and QUIC each retain an
affinity-aware I/O pool so whichever transport is being benchmarked can use
the full CPU set while the other pool sleeps. The HTTP/2 and HTTP/3 listeners
use Proxygen's benchmark-oriented flow-control, stream-concurrency, GSO
batching, and write-path settings.

| Listener | Endpoints | Subscribed profiles |
| --- | --- | --- |
| HTTP/1.1 `:8080` | `/baseline11`, `/pipeline`, `/json/{count}`, `/upload`, `/static/*`, `/ws` | `baseline`, `pipelined`, `limited-conn`, `json`, `json-comp`, `upload`, `static`, `echo-ws`, `echo-ws-pipeline`, `echo-ws-limited` |
| HTTP/1.1 TLS `:8081` | `/json/{count}`, `/static/*` | `json-tls`, `static-tls` |
| h2c `:8082` | `/baseline2`, `/json/{count}` | `baseline-h2c`, `json-h2c` |
| HTTP/2 TLS `:8443` | `/baseline2`, `/static/*` | `baseline-h2`, `static-h2` |
| HTTP/3 QUIC `:8443` | `/baseline2`, `/static/*` | `baseline-h3`, `static-h3` |

The JSON routes load the immutable dataset once, build each requested slice
and derived `total` fields per request, and serialize the live object with
Folly. Proxygen's standard content-compression path provides conditional gzip
for clients that advertise it. Uploads count bytes delivered through the body
callbacks rather than trusting `Content-Length`; static files are read from
disk for each request.

The WebSocket handler uses Proxygen's upgrade handshake (including its
per-connection `Sec-WebSocket-Accept` calculation) and implements incremental
RFC 6455 frame parsing. Client frames are unmasked before text or binary data
is echoed; fragmented messages, multiple frames per read, ping/pong, and close
frames are handled explicitly. This entry only claims WebSocket support over
HTTP/1.1, which is the protocol HttpArena's WebSocket profiles exercise.

## Upstream image and Docker build

The builder tracks the official `ghcr.io/facebook/proxygen/base:latest` image.
The final stage contains only the Arena binary and its resolved shared
libraries; its matching Ubuntu 24.04 runtime is pinned by digest. The final
image runs the servers as the unprivileged `httparena` user (UID/GID 10001).

The build and launch arrangement follows Proxygen's upstream container and
coroutine benchmark patterns:

- `Dockerfile`: build in a full Proxygen environment, discover runtime
  libraries with `ldd`, and copy them into a same-distribution runtime image.
- `HTTPCoroBenchmark.cpp`: configure QUIC with GSO batching, continuous-memory
  writes, a large congestion window, and a 48-packet write batch.

HttpArena mounts `/certs/server.crt`, `/certs/server.key`,
`/data/dataset.json`, and `/data/static` at runtime. No benchmark data is baked
into the image.

## Local validation

From the repository root on a host where the standard ports are free:

```bash
./scripts/validate.sh proxygen
```

The full benchmark driver is required for the complete 18-profile metadata set
(the lite driver currently rejects profiles it does not know about):

```bash
LOADGEN_DOCKER=true SKIP_TUNE=true ./scripts/benchmark.sh proxygen --save
```
