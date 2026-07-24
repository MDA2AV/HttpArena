# tokio-uring-ws

A WebSocket echo server on **tokio-uring** — the io_uring-backed Rust runtime
with a completion-based, owned-buffer API — with the WebSocket protocol
**hand-rolled** (no `tungstenite`, no library WS stack).

## Serving model

tokio-uring runs one runtime per thread, so this spawns one `tokio_uring::start`
per core, each with its own `SO_REUSEPORT` listener (built via `socket2` and
handed over with `TcpListener::from_std`). The kernel shards connections across
cores; there's no shared accept queue or cross-core work-stealing. Reads and
writes use tokio-uring's owned-buffer model: a `Vec<u8>` is passed by value into
`read`/`write_all` and handed back, so buffers are reused across iterations.

## Hand-rolled WebSocket

- **RFC 6455 handshake** — request parsing, `Sec-WebSocket-Accept` derivation,
  `101` reply, with from-scratch **SHA-1 + base64** (`src/main.rs`). Only deps
  are `tokio-uring` and `socket2`.
- **Frame codec** — 7/16/64-bit lengths, client→server unmasking, partial frames
  carried across reads. Echoes re-emitted as unmasked server frames preserving
  FIN + opcode. `Ping`→`Pong`, `Close` echoed.

A non-upgrade `GET /ws` is rejected with `400`; other paths return `404`.

## Build & run

io_uring requires `seccomp=unconfined` under Docker (the harness sets this):

```bash
docker build -t httparena-tokio-uring-ws .
docker run --rm --security-opt seccomp=unconfined --ulimit memlock=-1:-1 \
  -p 18080:8080 httparena-tokio-uring-ws
python3 ../../scripts/validate-ws.py localhost 18080 /ws
```
