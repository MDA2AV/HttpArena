# fib

[fib](https://github.com/lesismal/fib) (Fast In Balance), a Go networking library: one
edge-triggered event loop (epoll on Linux) feeding a logical worker pool, where each
connection owns an ordered event queue and any idle worker may run it, with no fixed
connection-to-thread binding.

## Stack

- **Language:** Go 1.27 (fib's own `go.mod` requires it)
- **Framework:** fib `http`, `http3`, `tls` and `middleware/compress` packages, no dependencies beyond the
  standard library. `pgx` for `/async-db`
- **Build:** `golang:1.27-alpine`, static binary on `scratch`

## Listeners

| Port | Protocol | fib API |
|------|----------|---------|
| 8080 | HTTP/1.1 | `fibhttp.NewHandler` |
| 8082 | HTTP/2 cleartext, prior knowledge | the same engine as 8080: fib tells HTTP/2 from HTTP/1.1 by the connection preface |
| 8081 | HTTP/1.1 over TLS, ALPN `http/1.1` | `fibtls.NewServer` in front of an HTTP handler with `DisableHTTP2` |
| 8443/tcp | HTTP/2 over TLS (ALPN `h2`), HTTP/1.1 otherwise | `fibtls.NewServer(fibhttp.ConfigureTLS(...))` |
| 8443/udp | HTTP/3 over fib's own QUIC | a UDP engine with `http3.NewHandler` |
| 9000 | HTTP/1.1 over TLS, the opt-in TLS hardening section (`tls_check`) | as 8081, with the certificate from `/certs-tls` picked per handshake |

All of them run the same `fibhttp.HandlerFunc`, which takes a `*http.Request` and a
`*fibhttp.Context` to respond through, whatever the protocol.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11`, `/baseline2` | GET, POST | Sum of the integer query parameters, plus the body on POST |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m`, gzipped when asked for |
| `/echo` | POST | Returns the request body verbatim |
| `/delay/{ms}` | GET | Answers `ms` after waiting that long |
| `/static/{file}` | GET | Serves `/data/static`, pre-compressed twin where the client takes one |
| `/async-db` | GET | Items in a price range from Postgres (`min`, `max`, `limit`) |

## Notes

- **Default configuration.** Every engine is built from `fib.DefaultConfig()` and every
  HTTP handler from fib's defaults; the only change is `DisableHTTP2` on 8081 and 9000,
  which serve HTTP/1.1 alone.
- fib has no router, so the handler switches on `r.URL.Path` itself. Query parameters come
  from `r.URL.Query()`, and request bodies arrive read whole (Content-Length or chunked)
  before the handler runs.
- **`tls_check`.** The 9000 listener chooses its certificate through
  `tls.Config.GetCertificate`, which reloads the pair when either file changes, so a renewed
  certificate is served without a restart; a pair caught halfway through being replaced does
  not load, and the last good one keeps being served. fib's TLS layer sends close_notify and
  crypto/tls issues session tickets, so every check in the section passes.
- `/async-db` sizes its `pgx` pool from `DATABASE_MAX_CONN`, as the profile's standard rule
  asks, rather than from `pgxpool`'s CPU-count default. A failed query answers 500.
- `/delay` does not hold a worker while it waits: the handler calls `Context.Retain`, which
  keeps the response open past its return, and a `time.AfterFunc` timer responds and calls
  `Release`. `/async-db` does the same around a goroutine running the query.
- `/static` goes through `net/http`'s `ServeContent` with the `Context` as its
  `ResponseWriter`, which is how fib documents serving files: on plaintext HTTP/1 the file
  goes to the socket by `sendfile`. The file is opened on every request, so a replaced file
  is served as it is on disk. The `.br`/`.gz` twin already on disk is chosen off
  `Accept-Encoding`; nothing is compressed at runtime.
- **Compression** is fib's own middleware: `/json` and `/async-db` are wrapped with
  `middleware.Chain(handler, compress.New())` at its defaults, which gzips a JSON body of a
  kilobyte or more per request when `Accept-Encoding` takes it, and sends it as it is when the
  client asks for nothing (`json-tls`, `json-h2c`). `/static` stays outside it: the middleware
  sees each response whole, which on HTTP/1 would keep files off `sendfile`, and the compressed
  variants of the static files are already on disk.
- **No gRPC.** fib's HTTP/2 serves plain requests, it has no gRPC layer.
- **No `fortunes`.** fib has no template engine, and the profile asks entries without one to
  leave it out.
- **`experimental`.** fib's first commit is from September 2026: very new work that has not
  proved itself in production yet, which is what that tier is for.
- **Completeness.** No router, so no routing and no path parameters from the framework.
  `middleware.Chain` composes ordered middleware that run before and after the handler, can
  answer in its place, and wrap the whole app or a single handler, so `middleware` is done
  (and used, for compression). The request arrives made (`*http.Request` with query, headers and a
  body buffered or streamed), so `request` is declared done. `Respond`/`WriteResponse` take
  status, headers and body in one call, but nothing serializes JSON, so `response` is not.
- WebSocket is a separate connection handler in fib, not a route on the HTTP handler, so the
  echo profiles are in [`fib-websocket`](../fib-websocket), as other entries do.
- [`fib-tuned`](../fib-tuned) is this entry with a compression middleware of its own that also
  codes brotli and zstd, which the standard rules would not allow here.
