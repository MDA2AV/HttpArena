# Proa

Proa compiles the Fortunes HTML component and serves HTTP/1.1, HTTP/2 (TLS + h2c), HTTP/3 (QUIC), gRPC, and WebSocket over thread-per-core Axum/Hyper workers with `mimalloc` v2, `SO_REUSEPORT`, `TCP_NODELAY`, `sonic-rs`, thread-local `libdeflater` gzip compression, TLS 1.3 (`TLS_AES_128_GCM_SHA256` via `aws-lc-rs`), `quinn` + `h3`, and per-worker `deadpool-postgres` pools.

- **`:8080` TCP**: HTTP/1.1 (`/baseline11`, `/pipeline`, `/delay/{ms}`, `/json/{count}`, `/echo`, `/async-db`, `/fortunes`), WebSocket (`/ws`), and cleartext h2c gRPC (`/benchmark.BenchmarkService/GetSum`).
- **`:8081` TCP (TLS 1.3, ALPN `http/1.1`)**: `/baseline11`, `/json/{count}`, and zero-copy `/echo`.
- **`:8082` TCP (h2c)**: `/baseline2` and `/json/{count}`.
- **`:8443` TCP (TLS 1.3, ALPN `h2`)**: `/baseline2`, `/static/*` (read fresh from disk with `.br`/`.gz` precompressed selection), and TLS gRPC (`/benchmark.BenchmarkService/GetSum`).
- **`:8443` UDP (QUIC / TLS 1.3, ALPN `h3`)**: per-worker `SO_REUSEPORT` `quinn` + `h3` serving `/baseline2` and `/static/*`.
