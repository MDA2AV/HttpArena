# viltrum

[viltrum](https://github.com/Tuntii/viltrum) is an HTTP framework for V with its own engine (no stdlib
`net.http` underneath). Docs: https://github.com/Tuntii/viltrum/tree/main/docs

This entry runs viltrum with its default configuration (standard mode).

| Profile | Endpoint | Notes |
|---------|----------|-------|
| baseline, limited-conn | `GET/POST /baseline11` | `c.query_int`, `c.body_int` (Content-Length or chunked) |
| pipelined | `GET /pipeline` | the engine batches pipelined responses into one write |
| json-comp | `GET /json/:count?m=` | `c.json` per request, `viltrum.gzip` middleware |
| async | `GET /delay/:ms` | `c.after` answers from a per-worker timer; the worker is not held while the request waits |
| json-tls | `GET /json/:count?m=` on 8081 | the json-comp handler; the client sends no `Accept-Encoding`, so nothing is compressed |
| 8gbit | `POST /echo` on 8081 | `c.body()` (Content-Length or chunked) back through `c.bytes` |
| baseline-h2 | `GET /baseline2` on 8443 | HTTP/2 over TLS, chosen by ALPN; the same handler and `Ctx` as HTTP/1.1 |
| static-h2 | `GET /static/*` on 8443 | `app.static_files` with `precompressed: true`: the `.br` or `.gz` copy on disk to a client that accepts it, read from disk on each request |
| baseline-h2c | `GET /baseline2` on 8082 | HTTP/2 with prior knowledge; the listener serves HTTP/1.1 too |
| json-h2c | `GET /json/:count?m=` on 8082 | the json-comp handler over h2c |

TLS is viltrum's own listener (`app.serve` with a `TlsOptions` listener), on the same epoll workers as
cleartext: TLS 1.3 preferred, 1.2 minimum, AEAD suites only. The common TLS 1.3 handshake (X25519, RSA-PSS)
and the AES-GCM records are viltrum's own code; the rest is mbedtls 3.6, the TLS library that ships with V.
ALPN offers `h2` then `http/1.1` on 8443 and `http/1.1` alone on 8081. Certificates are picked per handshake
and re-read when the files change, which is what `tls_check` exercises on port 9000.

HTTP/2 is viltrum's own as well: HPACK, framing, flow control and the RFC 9113 limits on the same workers,
requests through the same router, middleware and `Ctx` as HTTP/1.1.

The entry is typed `experimental`: viltrum's first commit is from July 2026, so it is new work
that has not proved itself in production yet, which is what that tier is for.
