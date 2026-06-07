# tokio-ws

A WebSocket echo server written directly on **raw tokio**, with the WebSocket
protocol **hand-rolled** — no `tokio-tungstenite`, no `wtx`, no WS library at all.

It exists as an `engine`-tier reference point: the lowest-level way to serve the
`echo-ws` profile on the tokio reactor, so the leaderboard shows what the runtime
itself can do once the framing is reduced to the minimum.

## What's implemented by hand

- **RFC 6455 handshake** — request parsing, `Sec-WebSocket-Accept` derivation,
  and the `101 Switching Protocols` reply. SHA-1 and base64 are both written
  from scratch (`src/main.rs`), so the only dependencies are `tokio` and
  `socket2`.
- **Frame codec** — a streaming parser that handles 7/16/64-bit lengths,
  client→server unmasking, and partial frames split across `read()`s. Echoes are
  re-emitted as unmasked server frames, preserving FIN + opcode (so fragmented
  messages pass through transparently).
- **Control frames** — `Ping` is answered with `Pong`; `Close` is echoed and the
  connection ends.

## Serving model

One `current_thread` tokio runtime per core, each binding `0.0.0.0:8080` with
`SO_REUSEPORT` so the kernel shards new connections across cores — no shared
accept queue, no cross-core work-stealing. `TCP_NODELAY` is set per connection,
and outgoing echoes are batched per read so a pipelined burst flushes in one
write. This mirrors the other one-thread-per-core engine entries (e.g.
`rust-epoll`).

## Endpoint

| Method | Path  | Behavior                                  |
|--------|-------|-------------------------------------------|
| GET    | `/ws` | WebSocket upgrade, then echo every frame  |

A non-upgrade `GET /ws` is rejected with `400`; other paths return `404`.

## Build & run

```bash
cargo build --release
./target/release/httparena-tokio-ws        # listens on :8080
python3 ../../scripts/validate-ws.py localhost 8080 /ws
```
