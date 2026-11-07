# aegon-java

[Aegon Java](https://github.com/UdayKhare09/Aegon) provides high-performance Java 22+ Foreign Function & Memory (FFM / Project Panama) bindings for the Linux-native [Aegon](https://github.com/UdayKhare09/Aegon) asynchronous web framework.

It bridges low-overhead C++26 `io_uring` reactor primitives directly into modern Java without JNI glue overhead, combining kernel-level I/O rings with Project Loom Virtual Threads and SIMD-accelerated Fastjson2 serialization.

## Stack

- **Language:** Java 22+ (OpenJDK / Eclipse Temurin)
- **Engine:** Linux `io_uring` multishot accept/recv, provided buffer rings via Panama FFM
- **Concurrency:** Inline native reactor dispatch for synchronous routes; automated Project Loom Virtual Threads for asynchronous non-blocking routes
- **Serialization:** Fastjson2 (SIMD-accelerated JSON parsing and generation)
- **Compression:** `libdeflate` gzip/deflate streaming middleware
- **Crypto & TLS:** Linux kTLS TX offload with OpenSSL TLS 1.3 and ALPN (`h2`, `http/1.1`)
- **HTTP/3:** Native QUIC/UDP protocol support via `libngtcp2` and `libnghttp3`
- **WebSocket:** RFC 6455 full-duplex WebSocket echo
- **Build:** Maven on Arch Linux

## Endpoints

| Endpoint | Method | Protocol | Description |
|---|---|---|---|
| `/pipeline` | GET | HTTP/1.1 | Pipelined plaintext response (`ok`) |
| `/baseline11` | GET | HTTP/1.1 | Fast query string parameter summation |
| `/baseline11` | POST | HTTP/1.1 | Sums query parameters and request body |
| `/baseline2` | GET | HTTP/2 | Baseline query summation over HTTP/2 |
| `/baseline2` | POST | HTTP/2 | Baseline query + body summation over HTTP/2 |
| `/delay/:ms` | GET | HTTP/1.1 | Non-blocking asynchronous delay via Project Loom Virtual Threads |
| `/json/:count?m=N` | GET | HTTP/1.1 & HTTP/2 | Fastjson2 serialization with `libdeflate` compression |
| `/echo` | POST | TLS | 8Gbit verbatim binary stream echo |
| `/static/*` | GET | TLS, HTTP/2 & HTTP/3 | High-throughput static file delivery via `router.staticFiles` |
| `/ws` | Upgrade | HTTP/1.1 (RFC 6455) | Full-duplex WebSocket echo with native `io_uring` batching |

## Ports & Protocols

Aegon Java runs concurrent multi-port listeners with protocol multiplexing:

- **Port 8080 (HTTP/1.1 Plaintext & WebSocket):** Primary plaintext and WebSocket benchmark port (`baseline`, `async`, `latency-*`, `pipelined`, `limited-conn`, `echo-ws`, `echo-ws-pipeline`, `echo-ws-limited`).
- **Port 8082 (HTTP/2 Cleartext / Prior Knowledge):** `h2c` benchmarking (`baseline-h2c`, `json-h2c`).
- **Port 8081 (HTTP/1.1 TLS):** Secure HTTP/1.1 workloads (`json-tls`, `8gbit`, `static-tls`).
- **Port 8443 (HTTP/2 TLS & HTTP/3 QUIC / UDP):** Secure HTTP/2 and HTTP/3 workloads (`baseline-h2`, `static-h2`, `baseline-h3`, `static-h3`).

## Completeness & Features

Aegon Java qualifies for 4/4 Completeness (100%, multiplier ×1.00):
- **Routing:** Parameterized path matching (`:ms`, `:count`), static prefix tree matching (`/static/*`), and RFC 6455 WebSocket routes (`/ws`).
- **Middleware:** Composable request/response middleware chain with streaming compression (`useCompress`).
- **Request:** Zero-copy URI decoding, query parsing, header lookup, route params, and body handling.
- **Response:** Fluent response builder, custom status codes, headers, streaming, and direct Fastjson2 serialization.

