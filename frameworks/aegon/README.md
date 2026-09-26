# aegon

[Aegon](https://github.com/UdayKhare09/Aegon) is a Linux-native C++26 asynchronous web framework powered by `io_uring` multishot primitives, coroutines, stepped SIMD vectorization, and compile-time data engines.

## Stack

- **Language:** C++26 (GCC 14)
- **Engine:** Linux `io_uring` multishot accept/recv, provided buffer rings
- **Serialization:** Glaze (compile-time reflection, zero-copy JSON)
- **Compression:** `libdeflate` gzip/deflate streaming middleware
- **Crypto & TLS:** OpenSSL with ALPN (`h2`, `http/1.1`)
- **WebSocket:** RFC 6455 frame parser with AVX2 SIMD payload unmasking and fast-path batched echo engine
- **Build:** CMake with Ninja on Arch Linux

## Endpoints

| Endpoint | Method | Protocol | Description |
|---|---|---|---|
| `/pipeline` | GET | HTTP/1.1 | Pipelined plaintext response (`ok`) |
| `/baseline11` | GET | HTTP/1.1 | Fast query string parameter summation |
| `/baseline11` | POST | HTTP/1.1 | Sums query parameters and request body |
| `/baseline2` | GET | HTTP/2 | Baseline query summation over HTTP/2 |
| `/baseline2` | POST | HTTP/2 | Baseline query + body summation over HTTP/2 |
| `/delay/:ms` | GET | HTTP/1.1 | Non-blocking asynchronous delay via `io_uring` timer coroutine |
| `/json/:count?m=N` | GET | HTTP/1.1 & HTTP/2 | Zero-copy Glaze JSON serialization with `libdeflate` compression |
| `/echo` | POST | TLS | 8Gbit verbatim binary stream echo |
| `/static/*` | GET | TLS, HTTP/2 & HTTP/3 | High-throughput static file delivery via `router.static_files` |
| `/ws` | Upgrade | HTTP/1.1 (RFC 6455) | Full-duplex WebSocket echo with SIMD unmasking and `io_uring` batching |

## Ports & Protocols

Aegon runs concurrent multi-port listeners with protocol multiplexing:

- **Port 8080 (HTTP/1.1 Plaintext & WebSocket):** Primary plaintext and WebSocket benchmark port (`baseline`, `async`, `latency-*`, `pipelined`, `limited-conn`, `echo-ws`, `echo-ws-pipeline`, `echo-ws-limited`).
- **Port 8082 (HTTP/2 Cleartext / Prior Knowledge):** `h2c` benchmarking (`baseline-h2c`, `json-h2c`).
- **Port 8081 (HTTP/1.1 TLS):** Secure HTTP/1.1 workloads (`json-tls`, `8gbit`).
- **Port 8443 (HTTP/2 TLS & HTTP/3 QUIC / UDP):** Secure HTTP/2 and HTTP/3 workloads (`baseline-h2`, `static-h2`, `baseline-h3`, `static-h3`).

## Completeness & Features

Aegon qualifies for 4/4 Completeness (100%, multiplier ×1.00):
- **Routing:** Parameterized path matching (`:ms`, `:count`), static prefix tree matching (`/static/*`), RFC 6455 WebSocket routes (`/ws`) with automatic `426 Upgrade Required` fallback.
- **Middleware:** Composable request/response middleware chain with streaming compression (`Compress`).
- **Request:** Zero-copy URI decoding, query parsing, header lookup, route params, body handling.
- **Response:** Fluent response builder, custom status codes, headers, streaming, and direct Glaze JSON serialization.

## Concurrency & CPU Sizing

Worker thread allocation dynamically inspects container resource constraints:
- Evaluates cgroup v2 (`/sys/fs/cgroup/cpu.max`) and cgroup v1 CFS bandwidth quotas.
- Evaluates CPU affinity masks (`sched_getaffinity`).
- Falls back to hardware concurrency, guaranteeing at least one worker and avoiding thread over-subscription under restricted CPU quotas (e.g., `latency-500k-8cpu`).
