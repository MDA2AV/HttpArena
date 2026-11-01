# micronaut-tuned

Same application as `micronaut-production`, with the server tuned. Tuned mode.

## Differences from `micronaut-production`

| Setting | Where | Effect |
|---------|-------|--------|
| io_uring for the worker and acceptor groups, with epoll then NIO fallback | `application.properties` | Uses the first transport available on the host |
| `micronaut.server.idle-timeout=-1s` | `application.properties` | No idle-connection handler in the pipeline |
| `micronaut.server.netty.validate-headers=false` | `application.properties` | Skips request header validation |
| `-Dio.netty.buffer.checkBounds=false`, `-Dio.netty.buffer.checkAccessible=false`, `-Dio.netty.leakDetection.level=disabled` | `Dockerfile` | Netty buffer safety checks off |
| `-XX:+UseParallelGC` | `Dockerfile` | Throughput oriented garbage collector |
| `-Dio.netty.allocator.type=pooled` | `Dockerfile` | Reuses Netty buffers across requests |
| Prepared-statement cache | `Database` | Reuses driver query metadata; each request still queries fresh rows |
| Native echo buffers | `BenchmarkController` | Buffers the request, then forwards its native bytes through Micronaut's response writer |
| Direct UTF-8 fortunes rendering | `FortunesController` | Escapes and renders every fresh result without constructing a whole-page String |
| `/delay/{ms}` completes on the request's own event loop | `BenchmarkController` | The wait is scheduled on the Netty event loop that runs the request, so no other thread is involved |

The acceptor and worker groups use the same transport preference: the server channel type is derived from the worker configuration, and an incompatible acceptor transport fails at startup.

No response bodies are precomputed or cached and routing, binding and serialization are the framework's own.

Dataset loading, PostgreSQL JSON tags and JSON responses use Micronaut Serialization. Tags are selected as text and decoded with the injected Serde mapper; Jackson Databind is excluded. Jackson Core remains the streaming backend.

| `/baseline2?a=1&b=1` | GET | Sums the query parameters, used by the HTTP/2 profiles |
| `/delay/{ms}` | GET | Answers after `ms` milliseconds without holding a request thread |
| `/static/{name}` | GET | Files from `/data/static`; a `.br` or `.gz` twin is sent as is when the client accepts it |
| `/ws` | WebSocket | Echoes every text and binary frame |
| `/async-db?min=10&max=50&limit=20` | GET | Async PostgreSQL range query; limits are clamped to 1–50 |
| `/fortunes` | GET | Queries and sorts the rows, then emits escaped HTML directly as UTF-8 |

## Ports

| Port | Protocol |
|------|----------|
| 8080 | HTTP/1.1 and cleartext HTTP/2 upgrade |
| 8081 | HTTP/1.1 over TLS |
| 8082 | Cleartext HTTP/2 (prior knowledge) |
| 8443 | HTTP/2 over TLS |
| 8443/UDP | HTTP/3 over QUIC |

HTTP/2 is switched on for the whole server (`micronaut.server.http-version=2.0`), TLS key material comes from `/certs/server.crt` and `/certs/server.key`.

Run `mvn verify` on JDK 27 for the serialization and escaping checks. The Docker build runs these tests too; the repository's `scripts/validate.sh micronaut-tuned` covers the HTTP contracts against PostgreSQL.
