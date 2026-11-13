# anole

[Anole](https://github.com/xuckless/anole) is a Zig server library: HTTP/1.1, HTTP/2, HTTP/3, WebSocket, gRPC and WebTransport from one router, with BoringSSL for TLS and the [zio](https://github.com/lalinsky/zio) runtime (io_uring where available, epoll otherwise, one executor per core).

The entry builds Anole v0.1.0 from its tag and uses only documented APIs with default settings:

- one process serves every port through `listeners`: 8080 (HTTP/1.1 + h2c), 8081 (HTTP/1.1 over TLS), 8082 (h2c), 8443 (HTTP/2 + HTTP/1.1 over TLS, and HTTP/3);
- query and path parameters through the router (`req.query`, `req.params`), JSON through `res.json`, compression through the framework's compression (`res.compress`, gzip/zstd/Brotli), static files through `app.staticDir` with the precompressed `.br`/`.gz` siblings;
- `/async-db` and the production-stack API on Anole's built-in PostgreSQL client (pool sized from `DATABASE_MAX_CONN`), cache-aside through the documented per-call result cache over Redis;
- WebSocket through `app.wsCallbacks`, gRPC through `app.grpcWith` on the code generated from `benchmark.proto` during the build;
- handlers that never wait (baseline, JSON, gRPC) are marked with `anole.noWait`, the documented API for that case; handlers that wait (`/delay`, `/echo`, `/async-db`, `/api/*`) are not.

The gateway profiles put a stock nginx in front (`proxy/`, `proxy-h3/`, `proxy-production/`); each compose file explains its CPU split.
