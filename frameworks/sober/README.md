# sober

[Sober](https://github.com/sober-lang/sober)'s standard library HTTP/1.1 server (`std/http` on `std/net`, TLS 1.3 from `std/tls`), default configuration.

## Stack

- **Language:** Sober 0.6.0
- **Framework:** none beyond the standard library: `std/http` (server, router, middleware, gzip), `std/json`, `std/tls`
- **Build:** the release tarball of the compiler (one static ELF, standard library built in) on `alpine`, static binary on `scratch`

## Endpoints

| Endpoint | Method | Port | Description |
|----------|--------|------|-------------|
| `/pipeline` | GET | 8080 | Returns `ok` (plain text) |
| `/baseline11` | GET | 8080 | Sums query parameter values |
| `/baseline11` | POST | 8080 | Sums query parameters + request body |
| `/delay/{ms}` | GET | 8080 | Sleeps `ms` milliseconds, returns `ms` |
| `/json/{count}?m=N` | GET | 8080, 8081 | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | 8080, 8081 | Returns the request body back verbatim |

## Notes

- Routing through a plain table of `http.Route` values (method, `:param` / `*rest` patterns, per-route
  `before` / `after` middleware, `Mount` / `Merge` to compose tables), dispatched with `http.Dispatch`
- The request arrives parsed: `http.Param`, `http.Query`, `http.Header`, a buffered body
  (Content-Length or chunked), `http.Form` and `http.JsonDoc`. The response is a value
  (`http.Text`, `http.Json`, or `http.Response{status, contentType, body | stream, headers}`)
- JSON serialized per request by `std/json` (`json.Encode`)
- gzip is the server's built-in response compression (`http.ServeConn(..., compress: http.Gzip{level: 3})`),
  negotiated per request off `Accept-Encoding`, with `Vary: Accept-Encoding`. The level is the documented
  `level` field of `http.Gzip`
- `json-tls` and `8gbit` listen on `8081` when `/certs/server.crt` and `/certs/server.key` (or `TLS_CERT` /
  `TLS_KEY`) can be read: `tls.Serve` hands each connection to the same route table only after the handshake,
  and `http.ServeWith` serves it over `tls.Recv` / `tls.Send`. TLS 1.3 only, X25519, AES-128-GCM and
  ChaCha20-Poly1305, no session resumption
- One task per connection (`net.Serve`), on a work-stealing scheduler with one worker per CPU in the
  affinity mask (capped by the cgroup `cpu.max` quota). io_uring with an acceptor per worker, epoll fallback
- Missing dataset file means an empty item list, the server still starts

## Deployment

The harness already runs entries this way; outside it:

- io_uring is blocked by Docker's default seccomp profile: `--security-opt seccomp=unconfined`
- the per-worker rings count against `RLIMIT_MEMLOCK` on kernels before 5.12: `--ulimit memlock=-1:-1`
- one fd per connection: `--ulimit nofile=1048576:1048576`
