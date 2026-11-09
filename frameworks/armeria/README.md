# Armeria

[Armeria](https://armeria.dev) 1.43 on Netty (epoll, BoringSSL).

| Port | Protocol | Profiles |
|------|----------|----------|
| 8080 | HTTP/1.1, h2c | baseline, pipelined, limited-conn, async, latency-*, json-comp, unary-grpc, echo-ws* |
| 8081 | HTTP/1.1 + TLS | json-tls, 8gbit, static-tls |
| 8082 | h2c (prior knowledge) | baseline-h2c, json-h2c |
| 8443 | h2 + TLS | baseline-h2, static-h2, unary-grpc-tls |

- Compression: `EncodingService` (gzip, brotli via brotli4j)
- Static files: `FileService` with `serveCompressedFiles(true)` for the `.br`/`.gz` siblings
- gRPC: `armeria-grpc`, WebSocket: `WebSocketService`
