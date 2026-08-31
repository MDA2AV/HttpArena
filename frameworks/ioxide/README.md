# ioxide

[ioxide](https://github.com/MDA2AV/ioxide) - a shared-nothing io_uring runtime for .NET -
consumed as its published NuGet packages (`ioxide`, `ioxide.pg`, `ioxide.timer`, `ioxide.file`,
`ioxide.http2`, `ioxide.ngtcp2`, `ioxide.nghttp3`), not vendored. One ring per reactor thread:
SO_REUSEPORT + multishot accept, multishot recv into a provided buffer ring, inline
IValueTaskSource continuations, raw-syscall io_uring (no liburing).

The HTTP/1.1 handler (request line, headers, Content-Length + chunked bodies, keep-alive,
pipelining, fragmented reads) is hand-written on the raw recv/send API - no HTTP framework.

## Profiles

| profile | how |
|---|---|
| baseline / pipelined / limited-conn / latency-1m | hand-rolled parser with a per-connection carry buffer |
| async | `ioxide.timer`: the deadline is an `IORING_OP_TIMEOUT` submitted with the request, so the wait is held by the kernel and completes on the reactor that owns the connection - no timer thread, no syscall per wait. One timer per connection, re-armed per request |
| json / json-comp | dataset parsed to a model at startup, serialized field-by-field per request; json-comp brotli-encodes per request when the client sends `Accept-Encoding: br` |
| json-tls / static-tls | h1 over TLS on `:8081`, kTLS TX offload (the kernel frames what the handler writes as plaintext) |
| static | `ioxide.file` hands out descriptors, not bytes: the header is framed in `HttpSession` and the body read off the ring straight into the connection's write slab behind it, so both leave in one flush with no copy. Content negotiation is HTTP, so it lives in the entry (`Precompressed.cs`): `.br`/`.gz` siblings are baked once at startup with the base content-type + `Content-Encoding` + `Vary`, and chosen per request by `Accept-Encoding` (br > gzip > identity) |
| upload | POST body drained against Content-Length, byte count returned |
| async-db | `ioxide.pg`: pooled ring-native Postgres connections per reactor, SCRAM-SHA-256, rows streamed straight from the driver's receive buffer into the response |
| baseline-h2 / static-h2 | pure-C# `ioxide.http2` over TLS on `:8443`, routes shared with h3 (`Multiplexed.cs`) |
| baseline-h3 / static-h3 | `ioxide.ngtcp2` + `ioxide.nghttp3` over QUIC on udp`:8443` |

## Env

Every knob ioxide exposes on the paths this entry uses is reachable from the environment, and each
one falls back to the **library's own default** (read off a throwaway options instance in
`Config.cs`) rather than to a literal copied into this entry. An unset variable therefore means
"whatever ioxide ships", not "whatever was true when this file was written".

The four values the entry deliberately differs on are marked ¹.

### Process

| var | default | |
|---|---|---|
| `IOXIDE_REACTORS` | `min(ProcessorCount, 64)` | one ring per reactor; the cap stops SMT oversubscribing |
| `IOXIDE_DATASET` | `/data/dataset.json` | |
| `IOXIDE_STATIC` | `/data/static` | |
| `TLS_CERT` / `TLS_KEY` | `/certs/server.crt` / `.key` | TLS turns on when both exist |

### Engine (`ServerConfig`)

| var | default | |
|---|---|---|
| `IOXIDE_SQ_ENTRIES` | `8192` | io_uring SQ/CQ depth |
| `IOXIDE_RECV_BUF_KB` | `16` ¹ | bytes per shared recv buffer (library: 32 KB) |
| `IOXIDE_RECV_SLOTS` | `256` ¹ | shared recv buffer-ring depth (library: 4096) |
| `IOXIDE_DUAL_STACK` | `0` | bind IPv6 sockets that also accept IPv4-mapped clients |
| `IOXIDE_INCREMENTAL` | `0` | per-connection recv rings (`IOU_PBUF_RING_INC`, kernel 6.12+); enabling it makes the two knobs above unused |
| `IOXIDE_INC_CONNS` / `_SLOTS` / `_BUF` | `4096` / `16` / `4096` | incremental ring geometry |

### TCP (`TcpOptions`)

| var | default | |
|---|---|---|
| `IOXIDE_PORT` | `8080` | |
| `IOXIDE_TLS_PORT` | `8081` | h1 over TLS |
| `IOXIDE_H2_PORT` | `8443` | h2 over TLS, and QUIC's UDP port |
| `IOXIDE_BACKLOG` | `1024` | `listen()` depth per SO_REUSEPORT listener |
| `IOXIDE_WRITE_SLAB_KB` | `128` ¹ | per-connection write buffer (library: 16 KB); 128 KB fits a static response in one slab so it sends without chunk-flushing |
| `IOXIDE_POOL_MAX` | `1024` | pooled connection objects per reactor |
| `IOXIDE_WRITE_OVERFLOW` | `grow` | `grow` reallocs one slab; `segmented` chains pooled slabs and flushes with one vectored `SENDMSG` |
| `IOXIDE_ZERO_COPY` | `0` | `IORING_OP_SEND_ZC`: trades the in-kernel copy for page-pinning plus a second completion, so it only pays off on large responses |
| `IOXIDE_RECV_QUEUE` | `64` | per-connection SPSC recv queue depth |

### UDP (`UdpOptions`, under QUIC)

| var | default | |
|---|---|---|
| `IOXIDE_UDP_SLOTS` | `16` | multishot recv slots per reactor |
| `IOXIDE_UDP_SOCKBUF` | `8388608` | a **request** the kernel clamps to `net.core.rmem_max`; ioxide logs the granted size. Raising the cap is not automatically better - ioxide measured the full 8 MiB costing ~45% at saturation, a deep standing queue replacing early drops |
| `IOXIDE_UDP_GRO` | `1` | coalesce a peer's datagram burst into one completion |

### QUIC (`QuicOptions` + `QuicEngine`)

| var | default | |
|---|---|---|
| `IOXIDE_QUIC_PORT` | `IOXIDE_H2_PORT` | |
| `IOXIDE_QUIC_CID_LEN` | `8` | connection-id length this endpoint mints; engine and listener are sourced from the same value so they cannot disagree |
| `IOXIDE_QUIC_ROUTING` | `forward` | `forward` hands a misdirected datagram to its owner over the post queue (free until a client migrates); `kernelfilter` attaches a cBPF program so the kernel routes by connection id |
| `IOXIDE_QUIC_PIN_MIGRATED` | `1` | claim a migrated peer's new address so forwarding stops |
| `IOXIDE_QUIC_IDLE_MS` | `60000` | transport-level backstop for a connection gone quiet |
| `IOXIDE_QUIC_RETENTION_BYTES` | `16777216` | per-connection send-retention high-water; past it a response streams paced by the peer's acks instead of buffering whole |

### TLS (`TlsOptions`)

| var | default | |
|---|---|---|
| `IOXIDE_KTLS_RX` | `1` ¹ | kernel receive offload (library: off). Experimental - roughly one first connection in twelve fails the handoff |
| `IOXIDE_TLS_HANDSHAKE_MS` | `10000` | give up on a handshake that stalls; also applies to QUIC |
| `IOXIDE_TLS_MIN_VERSION` | `default` | `default` \| `tls12` \| `tls13` |
| `IOXIDE_TLS_CIPHER_SUITES` | OpenSSL's | TLS 1.3 suites, OpenSSL naming |
| `IOXIDE_TLS_CIPHER_LIST` | OpenSSL's | TLS 1.2-and-below ciphers |

**kTLS TX is pinned on and deliberately not a knob.** The h1 handler writes *plaintext* into the
write slab and lets the kernel frame it - that is what lets a static file be read off the ring
straight into the slab behind its header. With TX offload off nothing encrypts: the handshake and
ALPN still succeed and every response then goes out in the clear (`curl` reports *wrong version
number*). The h2 path would survive it, since that runs through `TlsConnectionDualPipe` and
encrypts in userspace, but one `TlsOptions` backs both listeners.

Note that kTLS needs the `tls` kernel module (`modprobe tls`); without it the TLS ports fail at
`TCP_ULP` with `errno 2` and only the plaintext port serves.

### HTTP/2 (`Http2Options`) and HTTP/3 (`Nghttp3Options`)

| var | default | |
|---|---|---|
| `IOXIDE_H2_MAX_STREAMS` | `1000` | advertised *and* enforced - past it a stream is refused rather than allocated (CVE-2023-44487) |
| `IOXIDE_H2_WINDOW` | `1048576` | per-stream flow-control window |
| `IOXIDE_H2_MAX_FRAME` | `16384` | RFC 9113 floor |
| `IOXIDE_H2_MAX_REQUEST_BYTES` | `8388608` | ceiling on one request's headers plus body |
| `IOXIDE_H2_MAX_HEADER_LIST` | `65536` | bounds a header block across CONTINUATION frames |
| `IOXIDE_H2_STREAM_BODIES` | `0` | dispatch on HEADERS with the body arriving through a reader |
| `IOXIDE_QPACK_CAPACITY` | `0` | `0` keeps every header literal, which costs bytes but never blocks a stream on a table update |
| `IOXIDE_QPACK_BLOCKED_STREAMS` | `0` | raise together with the capacity above |

### Postgres (`PgOptions`)

| var | default | |
|---|---|---|
| `DATABASE_URL` | unset | `postgres://user:pass@host:port/db`; unset disables `/async-db` |
| `DATABASE_MAX_CONN` | `256` | process-wide budget; per-reactor pool is this / reactors, clamped 1..8 |
| `IOXIDE_PG_POOL` | derived | overrides that division outright |
| `IOXIDE_PG_MAX_RECV_BYTES` | `67108864` | |
| `IOXIDE_PG_TIMEOUT_MS` | `30000` | |
