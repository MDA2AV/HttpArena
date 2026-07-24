# sark

sark is a Rust HTTP framework built on the **dope** io_uring runtime: zero-copy
header parsing, thread-per-core with `SO_REUSEPORT`, type-safe routing via
proc-macros, and `cartel-pg` for Postgres. No serde, no tokio, no `Arc`/atomics.

## Stack

- **Language:** Rust 1.95 (edition 2024)
- **Runtime:** dope (io_uring, thread-per-core)
- **TLS:** shin (TLS 1.3, self-signed Ed25519)
- **HTTP/3:** dope-quic (native QUIC endpoint)
- **Postgres:** cartel-pg
- **Build:** Multi-stage, fat LTO, `debian:bookworm-slim` runtime

All dependencies are published on crates.io — this directory is a
self-contained Cargo workspace with no path dependencies outside it.

## Layout

```
sark/
  httparena/        # HTTP server library + binaries (h1, h2, h2c, h3, ws, json-tls)
  httparena-grpc/   # gRPC server (prost codec, generated from proto/)
  Dockerfile        # shared build; pick a binary with --build-arg BIN=<name>
```

The companion profiles (`sark-h2`, `sark-h3`, `sark-grpc`, `sark-gateway`, …)
build a specific binary from this workspace via their own `build.sh`.

## Binaries

| Binary | Profile(s) | Protocol |
|--------|------------|----------|
| `httparena-sark` | `sark` | HTTP/1.1 (plaintext) |
| `httparena-sark-ws` | `sark-websocket` | WebSocket |
| `httparena-sark-h2c` | `sark-h2c` | HTTP/2 cleartext (prior knowledge) |
| `httparena-sark-json-tls` | `sark-json-tls` | HTTP/1.1 over TLS 1.3 |
| `httparena-sark-h2` | `sark-h2`, `sark-static-h2` | HTTP/2 over TLS 1.3 (ALPN h2) |
| `httparena-sark-h3` | `sark-h3`, `sark-static-h3` | HTTP/3 over QUIC |
| `httparena-sark-grpc` | `sark-grpc`, `sark-grpc-tls` | gRPC over HTTP/2 |
