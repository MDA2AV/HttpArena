# Proxygen

[Meta's Proxygen](https://github.com/facebook/proxygen) serving every protocol
HttpArena exercises, using Proxygen's callback server APIs:

- `proxygen::HTTPServer` on TCP 8080 for HTTP/1.1 and RFC 6455 WebSocket
  upgrades, TCP 8081 for HTTP/1.1 over TLS (ALPN `http/1.1` only), TCP 8082 for
  prior-knowledge h2c, and TCP 8443 with TLS/ALPN `h2`.
- Proxygen's mvfst-backed `HQServer` with ALPN `h3` on UDP 8443.

Both server APIs run in one process, each with its own affinity-aware I/O pool,
so whichever transport is being benchmarked can use the full CPU set while the
other pool sleeps. Size them independently with `PROXYGEN_THREADS` and
`PROXYGEN_H3_THREADS` (`0` = available CPUs).

| Listener | Endpoints | Subscribed profiles |
| --- | --- | --- |
| HTTP/1.1 `:8080` | `/baseline11`, `/pipeline`, `/json/{count}`, `/upload`, `/static/*`, `/ws` | `baseline`, `pipelined`, `limited-conn`, `json`, `json-comp`, `upload`, `static`, `echo-ws`, `echo-ws-pipeline`, `echo-ws-limited` |
| HTTP/1.1 TLS `:8081` | `/json/{count}`, `/static/*` | `json-tls`, `static-tls` |
| h2c `:8082` | `/baseline2`, `/json/{count}` | `baseline-h2c`, `json-h2c` |
| HTTP/2 TLS `:8443` | `/baseline2`, `/static/*` | `baseline-h2`, `static-h2` |
| HTTP/3 QUIC `:8443` | `/baseline2`, `/static/*` | `baseline-h3`, `static-h3` |

The JSON routes load the immutable dataset once, then build each requested slice
and its derived `total` fields per request and serialize the live object with
Folly. Uploads count bytes delivered through the body callbacks rather than
trusting `Content-Length`.

## Static assets

`/data/static` is mounted read-only and does not change during a run, so every
file and its precompressed `.br` / `.gz` siblings are read once at startup into
an immutable table, and responses are non-owning `IOBuf` views over it: no disk
I/O, no compression, no copy and no allocation for the payload per request. Both
in-memory caching and serving the precompressed variants are explicitly allowed
for `engine` entries ("No specific rules"). Variant choice is a delimited token
match on `Accept-Encoding` honouring `q=0`, preferring brotli, then gzip, then
the byte-exact original — which is what a client that sends no `Accept-Encoding`
always gets. A lookup miss is a 404, so path traversal is impossible by
construction rather than by filtering.

This replaced a per-request `open`/`read` plus an on-the-fly gzip of every
CSS/JS/HTML response, which was costing about 80x throughput and 6.7x memory.

Response compression via Proxygen's `CompressionFilter` is therefore scoped to
`application/json`, the only content type still compressed at request time and
the one `json-comp` is scored on. The gzip level is Proxygen's default
(`Z_DEFAULT_COMPRESSION`); level 9 measured as a net loss, trading 2.3% of
throughput for 0.35% smaller bodies under the `(minBpr/myBpr)²` scoring.

The WebSocket handler uses Proxygen's upgrade handshake (including its
per-connection `Sec-WebSocket-Accept` calculation) and implements incremental
RFC 6455 frame parsing: client frames are unmasked before text or binary data is
echoed, and fragmented messages, multiple frames per read, ping/pong and close
frames are all handled. This entry claims WebSocket support over HTTP/1.1 only,
which is the protocol HttpArena's WebSocket profiles exercise.

## Shared source tree

`frameworks/proxygen` is the build context for **both** Proxygen entries. The
`TARGET` build arg picks the server, the same way `sark-h3` reuses `sark`:

| Entry | Build | Server API |
| --- | --- | --- |
| `proxygen` | `docker build frameworks/proxygen` | `src/ClassicServer.cpp` + `src/ArenaHQServer.cpp` |
| `proxygen-coro` | `frameworks/proxygen-coro/build.sh` (`--build-arg TARGET=coro`) | `src/CoroServer.cpp` |

`src/ArenaCommon.h` holds the routing, parsing, static-asset and validation
helpers both servers share, so a fix lands in both entries at once.

## Allocator

Both images `LD_PRELOAD` mimalloc (pinned by tag in the Dockerfile). glibc malloc
is the binding constraint on the allocation-heavy profiles — the JSON routes build
a live `folly::dynamic` per request (up to 50 item copies plus the serialized
string), and the coroutine server allocates a frame per event. Measured here it is
worth roughly +38% on `json` and +41%/+82% (classic/coro) on `json-comp`.
`MIMALLOC_PURGE_DELAY=1` is set because the default (10 ms) retains ~17% more
memory on `json-comp` at 16384 connections for no throughput gain; going to 0
would cut memory 4x further but costs 44% of that profile, so it is not used.

## Image

The builder tracks `ghcr.io/facebook/proxygen/base`, pinned by digest in
`ARG PROXYGEN_BASE` so a benchmark round is reproducible — bump it deliberately
rather than tracking `:latest`. The final stage contains only the Arena binary
and the shared libraries `ldd` resolves for it, on a digest-pinned Ubuntu 24.04,
running as the unprivileged `httparena` user (UID/GID 10001).

Note that the prebuilt Proxygen, folly, fizz, wangle and mvfst libraries in the
base image are built `RelWithDebInfo` (`-O2 -g -DNDEBUG`): `getdeps.py` defaults
`--build-type` to `RelWithDebInfo` and Proxygen's `docker/base.Dockerfile` does
not override it. Only this repository's translation unit is `-O3`.

HttpArena mounts `/certs/server.crt`, `/certs/server.key`, `/data/dataset.json`
and `/data/static` at runtime; no benchmark data is baked into the image.

## Local validation

From the repository root, on a host where the standard ports are free:

```bash
./scripts/validate.sh proxygen
./scripts/benchmark.sh proxygen baseline
```
