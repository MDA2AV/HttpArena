# viltrum

[viltrum](https://github.com/Tuntii/viltrum) is an HTTP framework for V with its own HTTP/1.1 engine
(no stdlib `net.http` underneath). Docs: https://github.com/Tuntii/viltrum/tree/main/docs

This entry runs viltrum with its default configuration (standard mode).

| Profile | Endpoint | Notes |
|---------|----------|-------|
| baseline, limited-conn | `GET/POST /baseline11` | `c.query_int`, `c.body_int` (Content-Length or chunked) |
| pipelined | `GET /pipeline` | the engine batches pipelined responses into one write |
| json-comp | `GET /json/:count?m=` | `c.json` per request, `viltrum.gzip` middleware |
| async | `GET /delay/:ms` | `c.after` answers from a per-worker timer; the worker is not held while the request waits |
| json-tls | `GET /json/:count?m=` on 8081 | the json-comp handler; the client sends no `Accept-Encoding`, so nothing is compressed |
| 8gbit | `POST /echo` on 8081 | `c.body()` (Content-Length or chunked) back through `c.bytes` |

TLS is viltrum's own listener (`app.serve` with a `TlsOptions` listener), on the same epoll workers as
cleartext. The crypto is mbedtls 3.6, the TLS library that ships with V (`thirdparty/mbedtls`, behind
`net.mbedtls`): TLS 1.3 preferred, 1.2 minimum, AEAD suites only, ALPN `http/1.1`. Certificates are picked per
handshake and re-read when the files change, which is what `tls_check` exercises on port 9000.

The entry is typed `experimental`: viltrum's first commit is from July 2026, so it is new work
that has not proved itself in production yet, which is what that tier is for.
