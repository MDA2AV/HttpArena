# minima-ws

A WebSocket echo server built on the **Minima** engine — a from-scratch C#
multi-reactor io_uring server — with the WebSocket protocol **hand-rolled** (no
`System.Net.WebSockets`, no library WS stack). It's the WebSocket counterpart to
the other zerg/io_uring engines in the arena.

## The engine (Minima, vendored unchanged)

Minima talks to io_uring through **direct libc syscalls** (`io_uring_setup` /
`io_uring_enter` via `syscall()`) — no liburing, no native shim. Each reactor is
one thread + one `io_uring` + one `SO_REUSEPORT` listener + its own connection
map, so the kernel shards connections across cores and per-connection state never
crosses threads. It uses **multishot accept**, **multishot recv into a shared
provided buffer ring**, `SINGLE_ISSUER | DEFER_TASKRUN`, and a pooled
per-connection write slab.

The engine sources under `Connection/`, `io_uring/`, `Reactor/`, `Utils/` and
`ServerConfig.cs` are vendored as-is. Only the request handler is ours.

## Hand-rolled WebSocket (`Program.cs`)

Minima's reactor calls `Handler.HandleAsync` per connection, handing us raw recv
buffers (`item.AsSpan()`) and a `Write`/`FlushAsync` path. On top of that:

- **RFC 6455 handshake** — request parsing, `Sec-WebSocket-Accept`, `101` reply
  (SHA-1 + base64 via the BCL).
- **Frame codec** — 7/16/64-bit lengths, client→server unmasking, partial frames
  carried across reads. Echoes re-emitted as unmasked server frames preserving
  FIN + opcode. `Ping`→`Pong`, `Close` echoed. Output is flushed in write-slab
  sized chunks, so frames larger than the slab stream correctly.

A non-upgrade `GET /ws` is rejected with `400`; other paths return `404`.

## Endpoint

| Method | Path  | Behavior                                 |
|--------|-------|------------------------------------------|
| GET    | `/ws` | WebSocket upgrade, then echo every frame |

## Build & run

io_uring requires `seccomp=unconfined` under Docker (the harness sets this):

```bash
docker build -t httparena-minima-ws .
docker run --rm --security-opt seccomp=unconfined --ulimit memlock=-1:-1 \
  -e MINIMA_REACTORS=4 -p 18080:8080 httparena-minima-ws
python3 ../../scripts/validate-ws.py localhost 18080 /ws
```

`MINIMA_REACTORS` overrides the reactor count (defaults to the core count).
