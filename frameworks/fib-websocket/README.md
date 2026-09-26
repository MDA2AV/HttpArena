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

- **Configuration**: `fib.DefaultConfig()` with `ReusePort` on, and `websocket.NewHandler`.
  fib's default configuration has `IOPollers` on and `IOPollerCount` at one event loop per CPU
  (`runtime.NumCPU`), which fib's documentation gives for connections whose rounds run on their
  loops, as WebSocket ones do. Without `IOPollers`, a single loop collects readiness for the
  whole server and hands every round to a worker, and on the 64-CPU benchmark host that loop,
  not the cores, set the pace: about 2,300% CPU on echo-ws and 1,100% on echo-ws-limited
  ([#1510](https://github.com/MDA2AV/HttpArena/issues/1510)).
- `ReusePort` has each of those loops listen on `:8080` with a socket of its own, bound with
  `SO_REUSEPORT`, and accept the connections the kernel spreads onto it, so a connection is
  accepted, served and closed on one loop. Without it the engine's own loop accepts every
  connection and wakes the loop it hands it to, and on echo-ws-limited, which reconnects after
  every ten messages, that one loop held the run near 95k connections/s on 35 of the 64 CPUs
  ([#1512](https://github.com/MDA2AV/HttpArena/pull/1512)).
- fib's `websocket.ServerHandler` is a connection handler of its own rather than a route on
  the HTTP handler: it answers the upgrade on the engine's connections and then parses frames
  from the buffer the event loop read into. A message is echoed with `WriteMessage` on the
  loop that read it, with no goroutine per connection. A request that is not an upgrade gets
  400.
- The handler sets no `Open` callback and no `CheckOrigin`, so fib validates the handshake
  without building an `*http.Request` for it.
