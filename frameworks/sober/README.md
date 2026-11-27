# sober

[Sober](https://github.com/sober-lang/sober)'s standard library HTTP server (`std/http/server` on `std/net`, TLS 1.3 from `std/tls`), default configuration: HTTP/1.1, and HTTP/2 with prior knowledge (h2c) on 8082.

## Stack

- Language: Sober 0.7.6
- Framework: none beyond the standard library: `std/http/server` (server, router, middleware, gzip), `std/json`, `std/tls`, `std/pg`
- Build: the release tarball of the compiler (one static ELF, standard library built in) on `alpine`, static binary on `scratch`.
  `sober build --profile=main.prof`: the server's hot-code profile places cold code blocks after the hot code (layout only)

## Endpoints

| Endpoint | Method | Port | Description |
|----------|--------|------|-------------|
| `/pipeline` | GET | 8080 | Returns `ok` (plain text) |
| `/baseline11` | GET | 8080 | Sums query parameter values |
| `/baseline11` | POST | 8080 | Sums query parameters + request body |
| `/baseline2` | GET | 8080, 8082 | Sums query parameter values (the h2c profiles) |
| `/delay/{ms}` | GET | 8080 | Sleeps `ms` milliseconds, returns `ms` |
| `/json/{count}?m=N` | GET | 8080, 8081, 8082 | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | 8080, 8081 | Returns the request body back verbatim |
| `/async-db?min=&max=&limit=` | GET | 8080 | Items with `price` between `min` and `max` from Postgres, up to `limit` (1 to 50) |
| `/spec`, `/spec/headers` | GET, HEAD, OPTIONS, POST | 8080, 8081 | The compliance route (h1 suite) |

## Notes

- Routing through a plain table of `http.server.Route` values (method, `:param` / `*rest` patterns, per-route
  `before` / `after` middleware, `Mount` / `Merge` to compose tables), dispatched with `http.server.Dispatch`
- The request arrives parsed: `http.server.Param`, `http.server.Query`, `http.server.Header` / `http.server.HeaderList`, a buffered body
  (Content-Length or chunked), `http.server.Form` and `http.server.JsonDoc`. The response is a value
  (`http.server.Text`, `http.server.Json`, or `http.server.Response{status, contentType, body | stream, headers}`)
- JSON serialized per request by `std/json` (`json.Encode`)
- gzip is the server's built-in response compression (`http.server.ServeConn(..., compression: http.server.Gzip{})`),
  at the default level, negotiated per request off `Accept-Encoding`, with `Vary: Accept-Encoding`
- `json-tls` and `8gbit` listen on `8081` when `/certs/server.crt` and `/certs/server.key` (or `TLS_CERT` /
  `TLS_KEY`) can be read: `tls.Serve` hands each connection to the same route table only after the handshake,
  and `http.server.ServeConn` serves it like a plain connection (the connection carries the TLS state). TLS 1.3 only, X25519, AES-128-GCM and
  ChaCha20-Poly1305, no session resumption
- `baseline-h2c` and `json-h2c` connect to `8082`: the same route table through `http.server.ServeConn(..., proto: http.server.H2)`
  (HTTP/2 with prior knowledge, RFC 9113). Each stream runs its route in a task of its own, so a slow route does not hold up
  the other streams of the connection
- One task per connection (`net.Serve`), on a work-stealing scheduler with one worker per CPU in the
  affinity mask (capped by the cgroup `cpu.max` quota). io_uring with an acceptor per worker, epoll fallback
- Missing dataset file means an empty item list, the server still starts
- `/async-db` goes through `std/pg`, the standard library's PostgreSQL client written in Sober (wire protocol 3.0,
  extended query with the statement prepared once per connection, SCRAM-SHA-256, no libpq). One pool for the
  process (`pg.OpenPool`: `DATABASE_MAX_CONN` less 6 connections, left for the harness's own `psql`), and each
  request borrows a connection for its query (`pg.With`). A connection is opened on first use, so the server
  starts even when Postgres does not answer; while it is unreachable `/async-db` returns `{"items":[],"count":0}`
  and the next request dials again. `tags` (JSONB) is copied into the response as Postgres sends it.
  The sidecar on the benchmark host has no TLS, so the pool runs with `pg.Policy{dangerouslyPlaintext: true}`
  (TLS 1.3 is `std/pg`'s default); the password comes from `DATABASE_URL`
- `/spec/headers` lists the request headers through `http.server.HeaderList`: names in lower case, in the order
  received, without the credential headers (`Authorization`, `Proxy-Authorization`, `Cookie`)

## Deployment

The harness already runs entries this way; outside it:

- io_uring is blocked by Docker's default seccomp profile: `--security-opt seccomp=unconfined`
- the per-worker rings count against `RLIMIT_MEMLOCK` on kernels before 5.12: `--ulimit memlock=-1:-1`
- one fd per connection: `--ulimit nofile=1048576:1048576`
