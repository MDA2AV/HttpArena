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

- **Configuration**: `fib.DefaultConfig()` and `websocket.NewHandler`, served through fib's
  `prefork` package as fiber's entry is through `EnablePrefork`: a master process starts a child
  for every two CPUs, each with two Ps, and every child listens on `:8080` with `SO_REUSEPORT`,
  so the kernel spreads the connections over them and each connection is accepted, served and
  closed in one child. One process with an event loop per four CPUs echoed about 2.96M messages
  a second on 64 CPUs, and 1.65M on echo-ws-limited, which reconnects after every ten
  messages.
- fib's `websocket.ServerHandler` is a connection handler of its own rather than a route on
  the HTTP handler: it answers the upgrade on the engine's connections and then parses frames
  from the buffer the event loop read into. A message is echoed with `WriteMessage` on the
  loop that read it, with no goroutine per connection. A request that is not an upgrade gets
  400.
- The handler sets no `Open` callback and no `CheckOrigin`, so fib validates the handshake
  without building an `*http.Request` for it.
