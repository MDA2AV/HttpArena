---
title: WebSocket
---

HttpArena drives the `echo-ws` profile with **gcannon in `--ws` mode**. The same io_uring engine documented under [HTTP/1.1 → gcannon](../h1/gcannon/) is reused here — worker threads, per-thread provided-buffer rings, multishot receives, per-connection state — with a frame-aware send/recv loop layered on top. Using one tool across transports keeps the client-side ceiling, threading model, and CPU-pinning behavior consistent so differences in the measurement land on the server, not the generator.

## Handshake

Each worker opens TCP connections and issues an HTTP/1.1 upgrade request to the target URL (typically `http://localhost:8080/ws`). The server must respond with `HTTP/1.1 101 Switching Protocols` and the correct `Sec-WebSocket-Accept` value derived from the client's `Sec-WebSocket-Key`. Connections that fail the handshake are reported as reconnects; the validator ([WebSocket validation](../../test-profiles/ws/echo/validation/)) checks the handshake path separately and catches framework-side bugs before benchmarks run.

## Echo loop

Once upgraded, each connection runs the steady-state loop:

1. Build a masked client-to-server text frame with a short payload
2. Send the frame via `io_uring_prep_send`
3. Wait for the server to echo it back (matched server-to-client frame)
4. On receipt, increment the per-thread frame counter and immediately send the next frame

Pipeline depth is 1 for the `echo-ws` profile — one message in flight per connection — so the measurement is effectively a back-to-back request/response loop rather than a batched burst. With thousands of concurrent connections each running this loop in parallel, the steady-state throughput reflects the server's ability to multiplex WebSocket frames across a large connection count without head-of-line blocking.

Both text frames (opcode `0x1`) and binary frames (opcode `0x2`) are exercised against the server during validation; benchmark runs use the text shape for simplicity. Framing follows RFC 6455: masked from client to server, unmasked from server to client, FIN bit set on every frame (no fragmented messages in the benchmark path).

## Command-line usage

```bash
gcannon http://localhost:8080/ws --ws \
        -c <connections> -t <threads> -d <duration> -p 1
```

| Flag | Description |
|------|-------------|
| `<url>` | The WebSocket endpoint served over HTTP/1.1 (uses `http://` scheme; the upgrade is implicit) |
| `--ws` | Switches gcannon from HTTP request mode into WebSocket echo mode |
| `-c` | Total concurrent connections (distributed evenly across `-t` threads) |
| `-t` | Worker threads (each owns an io_uring and a slice of connections; defaults to `$THREADS=64`) |
| `-d` | Test duration — `5s` for `echo-ws` |
| `-p` | Pipeline depth — fixed at `1` for `echo-ws` (one message in flight per connection) |

The profile dispatcher (`scripts/lib/tools/gcannon.sh:ws-echo`) wires all of this automatically when you invoke `./scripts/benchmark.sh <framework> echo-ws`.

## Output shape

gcannon reports WebSocket results with the same layout as HTTP requests, except the summary line reads "frames sent / frames received" instead of "requests / responses":

```
  2400000 frames sent     in 5.00s, 2400000 frames received
  Throughput: 480.00K frames/s
  WS frames: 2400000
```

The parser (`gcannon_parse ws-echo`) records `frames received` as the `status_2xx` equivalent and divides by the measured duration to produce the headline RPS number shown on the [WebSocket leaderboard](/leaderboards/websocket/). One echo round-trip counts as one unit — the frames-received count from the client side, not frames-sent, because the metric is "how many echoes the framework completed," not "how many messages the benchmarker pushed into the socket."

## Why not a dedicated WebSocket tool

The two common alternatives — `wrk2` with a Lua WebSocket plugin, or `artillery` — either can't saturate the server at 64-core scale (GC + per-connection Lua overhead becomes the bottleneck) or produce non-deterministic per-thread CPU pinning that makes cross-framework comparison unreliable. Reusing gcannon means the generator's tuning story is the same one already vetted against the HTTP/1.1 profiles, and the operator-side flags (`$GCANNON_CPUS`, cpuset pinning, provided buffer ring sizing) compose identically.
