# vanilla-h2c

HTTP/2 cleartext (h2c, prior-knowledge) on
[vanilla](https://github.com/enghitalo/vanilla)'s epoll engine, via the
conn-mode seam
([enghitalo/vanilla#136](https://github.com/enghitalo/vanilla/issues/136)) and
the http2 arm ([#122](https://github.com/enghitalo/vanilla/issues/122)): one
engine, the RFC 9113 state machine driven behind a `ConnHandler`.

## How it works

- **Takeover** — an http2 client's first bytes are the connection preface
  `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`. Its head parses as an ordinary HTTP/1.1
  request (method `PRI`, target `*`), so it reaches the pure `(request) -> bytes`
  handler. The handler queues the connection takeover (`core.queue_takeover`)
  and appends the server connection preface (a SETTINGS frame) as its switching
  response. The epoll worker flips the connection's mode: every subsequent
  readable burst — starting with the `SM\r\n\r\n` tail already buffered — is fed
  to the http2 `ConnHandler` instead of the HTTP/1.1 state machine.
- **Serve** — the `http2` module is a self-contained RFC 9113/7541 codec: HPACK
  (static + dynamic table, canonical Huffman decode, a decoded-block ceiling
  against compression bombs), the frame codec, and a stream state machine with
  send-side flow control, hardened against a live h2spec CI gate. `consume`
  surfaces each request only when COMPLETE (END_STREAM); the app routes it and
  the response goes back as HPACK-encoded HEADERS + DATA. SETTINGS/PING/
  WINDOW_UPDATE acks and RST_STREAM/GOAWAY errors are the machine's own.
- **h2c-only** — the `:8082` listener speaks cleartext HTTP/2 with prior
  knowledge only. A genuine HTTP/1.1 request is answered `505` and dropped,
  never a `200`, so the benchmark measures h2c throughput or nothing.
- **Engine reuse** — read buffering/compaction, batched flushes, EPOLLOUT
  backpressure and the timeout sweep are the HTTP engine's own, unchanged.
  Multi-threaded, SO_REUSEPORT, lock-free; built `-prod -gc none`.

## Routes

- `GET /baseline2?a=&b=` → `text/plain`, the integer sum `a+b`.
- `GET /json/{count}?m=` → `application/json`, `{"items":[…],"count":N}` — the
  vanilla `/json` shape (same `/data/dataset.json`, precomputed per-item
  prefixes, `total = price*quantity*m`).

## Tests

`baseline-h2c`, `json-h2c` (256 / 1024 / 4096 connections, h2 stream
multiplexing over cleartext TCP).

TLS-terminated h2 (`baseline-h2`, `static-h2`) is out of scope: vanilla's TLS
layer advertises only `http/1.1` via ALPN today, so this entry ships the
cleartext h2c profiles only.
