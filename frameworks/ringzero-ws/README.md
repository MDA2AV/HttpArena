# ringzero-ws

A WebSocket echo server written directly on **raw io_uring** (liburing), with the
WebSocket protocol **hand-rolled** — no `tokio-tungstenite`, no library WS stack.
It's the io_uring sibling of the `ringzero` HTTP engine, and an `engine`-tier
reference for what the modern Linux completion-based I/O path can do on `echo-ws`.

## The "ring-zero" I/O path

- **One `io_uring` per core**, each with its own `SO_REUSEPORT` listener — the
  kernel shards new connections across rings, so there's no shared accept queue
  and no cross-core work-stealing.
- **Multishot accept** — a single SQE yields every incoming connection.
- **Multishot recv + provided buffer ring** — recv is armed once per connection
  with `IOSQE_BUFFER_SELECT`; the kernel writes incoming bytes straight into a
  registered buffer slab (`io_uring_setup_buf_ring`) and hands back the buffer
  id per completion. Frames are parsed **in place** out of that buffer, which is
  recycled to the ring immediately after.
- **`IORING_SETUP_SINGLE_ISSUER | DEFER_TASKRUN`** for the single-thread-per-ring
  fast path (with a graceful fallback for older kernels).

Outgoing echoes are batched into a per-connection write queue so a pipelined
burst flushes in as few `send`s as possible, and the in-flight chunk is sealed
so the kernel never sees a reallocated buffer.

## Hand-rolled WebSocket

- **RFC 6455 handshake** — request parsing, `Sec-WebSocket-Accept` derivation,
  and the `101` reply, with from-scratch **SHA-1 + base64** (`main.c`). The only
  dependency is liburing.
- **Frame codec** — 7/16/64-bit lengths, client→server unmasking, partial frames
  carried across reads. Echoes are re-emitted as unmasked server frames
  preserving FIN + opcode. `Ping`→`Pong`, `Close` echoed.

## Endpoint

| Method | Path  | Behavior                                 |
|--------|-------|------------------------------------------|
| GET    | `/ws` | WebSocket upgrade, then echo every frame |

A non-upgrade `GET /ws` is rejected with `400`; other paths return `404`.

## Build & run

```bash
docker build -t httparena-ringzero-ws .
docker run --rm -p 18080:8080 httparena-ringzero-ws /server 8
python3 ../../scripts/validate-ws.py localhost 18080 /ws
```

`/server <N>` selects the reactor (thread) count; the benchmark image defaults
to `64`.
