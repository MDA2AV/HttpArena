# tokio-uring

A minimal **HTTP/1.1** server on **tokio-uring** — the io_uring-backed Rust
runtime with a completion/owned-buffer API — for the H1-isolated profiles
(`baseline`, `pipelined`, `limited-conn`). No HTTP framework.

## Serving model
One `tokio_uring::start` per core, each with its own `SO_REUSEPORT` listener
(`socket2` + `from_std`). Reads/writes use tokio-uring's owned-buffer model: a
`Vec<u8>` is passed by value into `read`/`write_all` and handed back, reused
across iterations. Responses are batched per read.

## Hand-rolled HTTP/1.1
Request line + headers, `Content-Length` **and** `Transfer-Encoding: chunked`
bodies, keep-alive, request pipelining, and fragmented-read reassembly.

| Endpoint | Response |
|---|---|
| `GET/POST /baseline11?a=&b=` | `text/plain` — `a + b` (+ POST body as an integer) |
| `GET /pipeline` | `text/plain` — `ok` |

io_uring requires `seccomp=unconfined` under Docker (the harness sets this;
`engine: "io_uring"` makes validate.sh enable it). `PORT` overrides the listen
port for local testing.
