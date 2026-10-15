# tako-grpc

The gRPC profiles for [Tako](https://github.com/rust-dd/tako) 2.4.1, reported as `tako`.

## Why a separate entry

`unary-grpc` sends cleartext HTTP/2 to port 8080, where the main [`tako`](../tako)
entry serves HTTP/1.1. A tako listener speaks either HTTP/1.1 or h2c, not both,
so the gRPC service gets its own container.

## Stack

- **Language:** Rust 1.99
- **Framework:** tako-rs 2.4.1 (`grpc`, `http2`, `tls`)
- **Protobuf:** prost 0.14
- **Build:** Multi-stage, `debian:trixie-slim` runtime

## Endpoints

| Port | Protocol | RPC |
|------|----------|-----|
| 8080 | h2c (prior knowledge) | `benchmark.BenchmarkService/GetSum` |
| 8443 | h2 over TLS | `benchmark.BenchmarkService/GetSum` |

## Notes

- `GetSum` is a plain `POST` route: the `GrpcRequest<SumRequest>` extractor
  decodes the frame and `GrpcResponse<SumReply>` writes the reply and the
  `grpc-status` trailer
- `SumRequest` and `SumReply` are prost messages matching `benchmark.proto`
- Both listeners run on tako's multi-thread `Server` with default
  configuration; TLS starts only when `/certs` is mounted
