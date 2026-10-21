# micronaut-tuned

Same application as `micronaut-production`, with the server tuned. Tuned mode.

## Differences from `micronaut-production`

| Setting | Where | Effect |
|---------|-------|--------|
| epoll native transport for the worker and the acceptor group | `application.properties` | Replaces the NIO selector; the largest single gain |
| `micronaut.server.idle-timeout=-1s` | `application.properties` | No idle-connection handler in the pipeline |
| `micronaut.server.netty.validate-headers=false`, `micronaut.server.validate-url=false` | `application.properties` | Skips request header and URL validation |
| `-Dio.netty.buffer.checkBounds=false`, `-Dio.netty.buffer.checkAccessible=false`, `-Dio.netty.leakDetection.level=disabled` | `Dockerfile` | Netty buffer safety checks off |
| `-XX:+UseParallelGC` | `Dockerfile` | Throughput oriented garbage collector |

The acceptor group has to be set to epoll as well: the server channel type is derived from the worker configuration, and on Micronaut 5.2 the implicitly created acceptor group stays on NIO, which fails at startup with `incompatible event loop type`.

No response bodies are precomputed or cached and routing, binding and serialization are the framework's own.
