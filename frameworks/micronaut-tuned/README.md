# micronaut-tuned

Same application as `micronaut-production`, with the server tuned. Tuned mode.

## Differences from `micronaut-production`

| Setting | Where | Effect |
|---------|-------|--------|
| epoll native transport for the worker and the acceptor group | `application.properties` | Replaces the NIO selector; the largest single gain |
| `micronaut.server.idle-timeout=-1s` | `application.properties` | No idle-connection handler in the pipeline |
| `micronaut.server.netty.validate-headers=false` | `application.properties` | Skips request header validation |
| `-Dio.netty.buffer.checkBounds=false`, `-Dio.netty.buffer.checkAccessible=false`, `-Dio.netty.leakDetection.level=disabled` | `Dockerfile` | Netty buffer safety checks off |
| `-XX:+UseParallelGC` | `Dockerfile` | Throughput oriented garbage collector |
| `/delay/{ms}` completes on the request's own event loop | `BenchmarkController` | The wait is scheduled on the Netty event loop that runs the request, so no other thread is involved |

The acceptor group has to be set to epoll as well: the server channel type is derived from the worker configuration, and on Micronaut 5.2 the implicitly created acceptor group stays on NIO, which fails at startup with `incompatible event loop type`.

No response bodies are precomputed or cached and routing, binding and serialization are the framework's own.
| `/baseline2?a=1&b=1` | GET | Sums the query parameters, used by the HTTP/2 profiles |
| `/delay/{ms}` | GET | Answers after `ms` milliseconds without holding a request thread |
| `/static/{name}` | GET | Files from `/data/static`; a `.br` or `.gz` twin is sent as is when the client accepts it |
| `/ws` | WebSocket | Echoes every text and binary frame |

## Ports

| Port | Protocol |
|------|----------|
| 8080 | HTTP/1.1 and cleartext HTTP/2 upgrade |
| 8081 | HTTP/1.1 over TLS |
| 8082 | Cleartext HTTP/2 (prior knowledge) |
| 8443 | HTTP/2 over TLS |

HTTP/2 is switched on for the whole server (`micronaut.server.http-version=2.0`), TLS key material comes from `/certs/server.crt` and `/certs/server.key`.
