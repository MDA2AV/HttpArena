# proxygen-coro

This engine exercises Proxygen's native coroutine server stack rather than the
callback `RequestHandler` / `HTTPTransactionHandler` APIs used by the regular
`proxygen` entry.

`ArenaCoroServer.cpp` implements `proxygen::coro::HTTPHandler`, consumes
requests through `HTTPSourceHolder`, and returns `HTTPFixedSource` responses.
Uploads are counted while asynchronously draining BODY events. WebSockets use
a long-lived custom `HTTPSource`: its response calls
`setEgressWebsocketUpgrade()`, then parses and emits RFC 6455 frames over the
raw upgraded BODY event stream. Response compression is provided by the coro
`ServerCompressionFilterFactory`.

## Listener layout

One process owns all five listeners:

- `8080/tcp`: HTTP/1.1 and WebSockets
- `8081/tcp`: HTTP/1.1 over TLS, ALPN `http/1.1`
- `8082/tcp`: prior-knowledge h2c
- `8443/tcp`: HTTP/2 over TLS, ALPN `h2`
- `8443/udp`: HTTP/3 over QUIC, ALPN `h3`

The four TCP listeners are acceptors on one coro `HTTPServer`, so they share a
single affinity-aware I/O pool. Proxygen's coro API selects either TCP or QUIC
per server, so HTTP/3 uses a second in-process pool; whichever transport is not
being benchmarked remains idle. Override the available-CPU default with
`PROXYGEN_CORO_THREADS`.

HTTP/2 advertises 1024 concurrent streams with a 1 MiB stream window and a
10 MiB connection window. HTTP/3 mirrors Proxygen's coroutine benchmark
settings: GSO batches of 48 packets, continuous-memory writes, a large
congestion window, and a 48-packet connection write limit.

## Upstream image and build

The self-contained Docker build tracks the official
`ghcr.io/facebook/proxygen/base:latest` builder image. The runtime stage copies
only the compiled binary and its dynamically linked libraries into a pinned
Ubuntu 24.04 image, then runs as the non-root `httparena` user (UID/GID 10001).

From the repository root:

```bash
./scripts/validate.sh proxygen-coro
./scripts/run.sh proxygen-coro
```

The implementation follows the upstream coroutine echo server and the
`H12DownstreamSessionTest.WebSocketUpgrade` test, which documents upgraded
raw bytes flowing through coroutine BODY events.
