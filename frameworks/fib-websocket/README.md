# fib (WebSocket)

WebSocket echo on [fib](https://github.com/lesismal/fib)'s `websocket` package, the WebSocket
side of the [`fib`](../fib) entry.

## Stack

- **Language:** Go 1.27 (fib's own `go.mod` requires it)
- **Framework:** fib `websocket` package, no dependencies beyond the standard library
- **Build:** `golang:1.27-alpine`, static binary on `scratch`

## Endpoint

| Endpoint | Description |
|----------|-------------|
| `/ws` on 8080 | Echoes every text and binary message back with its opcode |

## Notes

- **Default configuration**: `fib.DefaultConfig()` and `websocket.NewHandler`.
- fib's `websocket.ServerHandler` is a connection handler of its own rather than a route on
  the HTTP handler: it answers the upgrade on the engine's connections and then parses frames
  from the buffer the event loop read into. A message is echoed with `WriteMessage` on the
  worker that read it, with no goroutine per connection. A request that is not an upgrade gets
  400.
- The handler sets no `Open` callback and no `CheckOrigin`, so fib validates the handshake
  without building an `*http.Request` for it.
