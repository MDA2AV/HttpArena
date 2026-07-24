# tokio

A minimal **HTTP/1.1** server on raw **tokio** — no HTTP framework. It serves the
H1-isolated profiles (`baseline`, `pipelined`, `limited-conn`) with a hand-rolled
request parser on a tokio `TcpStream`.

## Serving model
One `current_thread` tokio runtime per core, each binding `:8080` with
`SO_REUSEPORT` (kernel-sharded accept, no cross-core work-stealing), `TCP_NODELAY`
per connection. Responses are batched per read, so a pipelined burst flushes in
one write.

## Hand-rolled HTTP/1.1
Request line + headers, `Content-Length` **and** `Transfer-Encoding: chunked`
bodies, keep-alive (multiple requests per connection), request pipelining, and
fragmented-read reassembly (requests split across `recv`s).

| Endpoint | Response |
|---|---|
| `GET/POST /baseline11?a=&b=` | `text/plain` — `a + b` (+ POST body as an integer) |
| `GET /pipeline` | `text/plain` — `ok` |

`PORT` overrides the listen port for local testing (defaults to 8080).
