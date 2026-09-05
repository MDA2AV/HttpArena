# sockets

HTTP/1.1 written directly on `System.Net.Sockets`, with no server library above it.

`cadente` is managed sockets with a server around them; this is the socket layer on its own, so the
distance to anything built on top reads as what that layer adds.

## Shape

- **One listening socket per core**, via `SO_REUSEPORT`. A single listener makes the accept queue a
  point every core contends on, and the thread that accepts is rarely the one that serves. Here the
  kernel hashes connections across per-thread listeners, so a connection is accepted, read and
  answered on one thread — the same shape the io_uring entries get from per-reactor rings.
- **One write per batch.** A pipelined client puts many requests in one segment; each response is
  appended to a write buffer and the buffer is flushed when the parse runs out of complete
  requests. The unpipelined case is the same path with a batch of one.
- **No allocation on the request path.** Headers are not collected into a dictionary: the parse
  looks for the three the profiles read (`Content-Length`, `Accept-Encoding`, `Connection`) and
  steps over the rest without touching their bytes. Nothing becomes a string.
- **`Date` is rendered once a second**, not once a request — its resolution is one second, so
  formatting it per request would be the same bytes several hundred thousand times over.

## Scope

HTTP/1.1 on `:8080`, and the same over TLS on `:8081` through `SslStream` — which is where `json-tls` and `8gbit` are measured. HTTP/2 would mean HPACK and framing by hand, HTTP/3 a QUIC
stack, and neither says anything more about what the socket layer costs.

`/json` is serialized from the parsed model on every request and compressed only when the client
asked for it — no precomputed bodies.
