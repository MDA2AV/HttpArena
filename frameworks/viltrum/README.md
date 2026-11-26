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
| connections-1m | `GET /baseline11` on 8080 | the baseline handler; nothing is tuned for the fleet (see below) |
| connections-1m-tls | `GET /baseline11` on 8081 | the same over TLS 1.3 |
| json-tls | `GET /json/:count?m=` on 8081 | the json-comp handler; the client sends no `Accept-Encoding`, so nothing is compressed |
| 8gbit | `POST /echo` on 8081 | `c.body()` (Content-Length or chunked) back through `c.bytes` |
| static-tls | `GET /static/*` on 8081 | the static-h2 handler (below) over HTTP/1.1 and TLS 1.3 |
| async-db | `GET /async-db?min=&max=&limit=` | our own Postgres client (wire protocol, SCRAM-SHA-256), one thread per connection, sized from `DATABASE_MAX_CONN`; the worker parks with `c.suspend` until `app.wake` |
| fortunes | `GET /fortunes` | the async-db pool and parking; the page is rendered on the worker with V's compile-time template (`fortunes.html`) |
| baseline-h2 | `GET /baseline2` on 8443 | HTTP/2 over TLS, chosen by ALPN; the same handler and `Ctx` as HTTP/1.1 |
| static-h2 | `GET /static/*` on 8443 | `app.static_files` with `precompressed: true`: the `.br` or `.gz` copy on disk to a client that accepts it, from the handler's per-worker cache, which stats the file on each request |
| baseline-h2c | `GET /baseline2` on 8082 | HTTP/2 with prior knowledge; the listener serves HTTP/1.1 too |
| json-h2c | `GET /json/:count?m=` on 8082 | the json-comp handler over h2c |
| spec (h1, h2, ws) | `/spec`, `/spec/headers` on 8080, 8443, 8082; `/ws` | the compliance route: GET/HEAD text, OPTIONS with `Allow`, POST echo through `c.body()`, the parsed header fields back one per line |

TLS is viltrum's own listener (`app.serve` with a `TlsOptions` listener), on the same epoll workers as
cleartext: TLS 1.3 preferred, 1.2 minimum, AEAD suites only. The common TLS 1.3 handshake (X25519, RSA-PSS)
and the AES-GCM records are viltrum's own code; the rest is mbedtls 3.6, the TLS library that ships with V.
ALPN offers `h2` then `http/1.1` on 8443 and `http/1.1` alone on 8081. Certificates are picked per handshake
and re-read when the files change, which is what `tls_check` exercises on port 9000.

HTTP/2 is viltrum's own as well: HPACK, framing, flow control and the RFC 9113 limits on the same workers,
requests through the same router, middleware and `Ctx` as HTTP/1.1.

The entry is typed `experimental`: viltrum's first commit is from July 2026, so it is new work
that has not proved itself in production yet, which is what that tier is for.

## Held connections

The defaults already fit CON-1M: every listener is on `0.0.0.0`, there is no connection cap
(`max_conns` 0), the keep-alive idle timeout is 60 s, and a connection holds no read or write buffer
while it is quiet (buffers are lent per event from the worker's pools). On an 8-vCPU VM with 4
workers, 100,000 held cleartext connections cost the server about 0.6 KB each and 50,000 TLS 1.3
connections about 6 KB each (the TLS session and the two AES-GCM key tables), with CPU per request
the same as at 10,000 connections.

## Database

`async-db` and `fortunes` read `DATABASE_URL` and size the pool from `DATABASE_MAX_CONN` (minus the
handful of connections Postgres reserves). There is no client library: `pg.v` speaks the Postgres wire
protocol itself, one blocking thread per connection, and prepares both queries once per connection.
The worker does not block on it: the request is parked with `c.suspend` and resumed with `app.wake`
when the query's thread has the rows. With no `DATABASE_URL`, or when Postgres is down, `async-db`
answers `{"items":[],"count":0}` and `fortunes` answers 503.

`fortunes` appends the request-time row, sorts by message in byte order, and renders `fortunes.html`
with `$tmpl`, V's compile-time template engine (documented syntax, `@for`, interpolation, a separate
file, run per request). One caveat: `$tmpl` escapes HTML only inside veb's `$veb.html()`, which writes
to a veb context, so `fortunes.html` calls `html.escape` (V's `encoding.html`) on the message itself
rather than relying on an escaping default.

`main.v` also has the `gateway-64` server behind `benches/httparena/compose.gateway.yml` in the
viltrum repo, but the entry does not subscribe to it.
