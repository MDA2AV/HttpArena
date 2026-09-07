# fiber-websocket

The WebSocket half of the `fiber` entry: Fiber 3 with
[gofiber/contrib](https://github.com/gofiber/contrib) `websocket` v1.2.5, which wraps
`fasthttp/websocket`.

It carries `display_name: fiber`, so its results merge into the same leaderboard row as
`frameworks/fiber`, the way `actix-websocket` merges into `actix`. `completeness` is omitted:
the field is never applied on the WebSocket board.

## Stack

- Fiber 3 on fasthttp
- `github.com/gofiber/contrib/v3/websocket` for the upgrade and the frame codec
- prefork, one worker per CPU the container is given, same as `frameworks/fiber`

## Endpoints

| Route | Profiles |
|-------|----------|
| `GET /ws` | `echo-ws`, `echo-ws-pipeline`, `echo-ws-limited` |

A plain `GET /ws` without upgrade headers answers 426, which the middleware does before it
copies the request.

## The echo loop

`ReadMessage` is a helper over `NextReader` that runs `io.ReadAll`, so it allocates a 512-byte
payload slice per message whatever the message weighs. Draining `NextReader` into a buffer the
connection already owns leaves the 8-byte `messageReader` as the only allocation, and
`WriteMessage` answers on the server fast path, which frames straight into the write buffer and
keeps its writer on the stack. One buffered read, one write.

The buffer starts at 1 KiB and doubles for anything larger. `SetReadLimit` caps a single message
at 1 MiB and is what bounds it; above that the library sends 1009 and the connection closes.

## Notes

- **The handler closes the connection itself.** The middleware closes a hijacked socket only when
  the handler panics, and it sets `KeepHijackedConns`, which stops fasthttp from closing it
  either. Without the `defer`, every finished connection leaks a descriptor.
- **Buffer sizes are the middleware defaults**, 1024 each way. At 5-byte frames a 1 KiB read
  buffer already holds around ninety of them, and raising both at 16k connections would cost
  ~100 MB for nothing.
- **Why this is standard.** The profile rule asks for "the framework standard WebSocket API with
  default buffer sizes", and `echo-ws-pipeline` adds "no custom batching or read-ahead
  optimizations". The loop uses documented `Conn` methods at default buffer sizes and reads
  exactly one message per `NextReader`: nothing is batched across messages and no frame parser is
  hand-rolled. For prefork the argument is the sibling's, see
  [`../fiber/README.md`](../fiber/README.md).
- **Not subscribed:** every HTTP profile. This entry serves `/ws` only, `frameworks/fiber` covers
  the rest of the row.
