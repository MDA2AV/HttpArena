# proxygen-coro

The same workload as the [`proxygen`](../proxygen/README.md) entry, served
through Proxygen's native coroutine stack instead of the callback
`RequestHandler` / `HTTPTransactionHandler` APIs.

`src/CoroServer.cpp` implements `proxygen::coro::HTTPHandler`, consumes requests
through `HTTPSourceHolder` and returns `HTTPFixedSource` responses. Uploads are
counted while asynchronously draining BODY events. WebSockets use a long-lived
custom `HTTPSource`: its response calls `setEgressWebsocketUpgrade()`, then it
parses and emits RFC 6455 frames over the raw upgraded BODY event stream.

Response compression is proxygen's coro `CompressionFilter`, attached by the
handler to the JSON responses rather than registered as a
`ServerCompressionFilterFactory` on `HTTPServer::Config`. The reason is that
`HTTPFilterFactoryHandler` calls `makeFilters()` *before* the request headers
have been read, so a server-level factory cannot be conditional: it allocates a
`SharedCtx`, a `VisitorFilter` holding a capturing lambda, a `CompressionFilter`
and a coroutine frame on **every** request, including `baseline`, where nothing
is compressible. That measured at ~10% of baseline throughput on this workload.
The classic `HTTPServer` path has no equivalent cost, because
`CompressionFilterFactory::onRequest` can see the request and returns the
handler unwrapped when there is nothing to compress.

## Listener layout

One process owns all five listeners:

- `8080/tcp` HTTP/1.1 and WebSockets
- `8081/tcp` HTTP/1.1 over TLS, ALPN `http/1.1`
- `8082/tcp` prior-knowledge h2c
- `8443/tcp` HTTP/2 over TLS, ALPN `h2`
- `8443/udp` HTTP/3 over QUIC, ALPN `h3`

The four TCP listeners are acceptors on one coro `HTTPServer`, so they share a
single affinity-aware I/O pool. Proxygen's coro API selects either TCP or QUIC
per server, so HTTP/3 uses a second in-process pool; whichever transport is not
being benchmarked stays idle. Size the two pools with `PROXYGEN_THREADS` and
`PROXYGEN_H3_THREADS` (`0` = available CPUs).

HTTP/2 advertises 1024 concurrent streams with a 1 MiB stream window and a
10 MiB connection window. HTTP/3 mirrors Proxygen's coroutine benchmark
settings: GSO batches of 48 packets, continuous-memory writes, a large
congestion window and a 48-packet connection write limit.

## Build

This entry has no Dockerfile of its own. `build.sh` builds the
`frameworks/proxygen` context with `--build-arg TARGET=coro`, the same pattern
`sark-h3` uses to reuse `sark`. See
[the proxygen README](../proxygen/README.md#shared-source-tree) for the layout
and image details.

```bash
./scripts/validate.sh proxygen-coro
./scripts/run.sh proxygen-coro
```

The implementation follows the upstream coroutine echo server and the
`H12DownstreamSessionTest.WebSocketUpgrade` test, which documents upgraded raw
bytes flowing through coroutine BODY events.
