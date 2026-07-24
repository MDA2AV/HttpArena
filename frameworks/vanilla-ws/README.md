# vanilla-ws

WebSocket echo server on [vanilla](https://github.com/enghitalo/vanilla)'s
epoll engine, via the conn-mode seam
([enghitalo/vanilla#136](https://github.com/enghitalo/vanilla/issues/136)):
one engine, two protocols on the same connection.

## How it works

- **Upgrade** — the HTTP handler stays a pure `(request) -> bytes` function.
  On `GET /ws` with a well-formed RFC 6455 handshake it appends the
  `101 Switching Protocols` (accept-key written base64-straight into the
  response buffer), queues the connection takeover (`core.queue_takeover`)
  and returns. The epoll worker flips the connection's mode: every subsequent
  readable burst is fed to a `ConnHandler` instead of the HTTP/1.1 state
  machine. Bytes pipelined in the same segment as the upgrade request are
  consumed by the takeover drain, never the HTTP parser.
- **Echo** — the `websocket` module is a pure RFC 6455 codec: frame-head
  parsing (with the full malformed matrix), in-place unmasking, unmasked
  server-frame writers. The conn handler walks every complete frame in the
  burst — text/binary echoed, ping answered with pong, close handshake
  completed — so a pipelined batch (echo-ws-pipeline) is drained in one call
  and coalesced into one write. Partial frames are buffered and compacted by
  the engine, which re-calls with the tail.
- **Engine reuse** — read buffering, batched flushes, EPOLLOUT backpressure
  and the timeout sweep are the HTTP engine's own, unchanged. Multi-threaded,
  SO_REUSEPORT, lock-free; built `-prod -gc none`.

## Tests

`echo-ws`, `echo-ws-pipeline` (512 / 4096 / 16384-byte payloads).
