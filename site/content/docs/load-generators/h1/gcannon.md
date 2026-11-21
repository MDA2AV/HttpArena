---
title: gcannon
seo_title: "gcannon: io_uring HTTP/1.1 Load Generator"
description: "gcannon is HttpArena's purpose-built HTTP/1.1 load generator, using Linux io_uring for zero-copy networking at very high request rates."
---

gcannon is a custom HTTP load generator built specifically for HttpArena. It uses Linux's `io_uring` interface for high-performance, zero-copy networking, ensuring the benchmarking tool itself never becomes the bottleneck.

## Why a custom load generator?

Traditional HTTP benchmarking tools like `wrk` or `ab` use `epoll` or `kqueue` for I/O multiplexing. While effective, these tools can become the bottleneck when testing extremely fast servers (millions of requests per second). gcannon uses `io_uring` to push the client-side ceiling higher.

## Architecture

gcannon spawns **N worker threads**, each managing its own:

- **io_uring ring** with `IORING_SETUP_SINGLE_ISSUER` and `IORING_SETUP_DEFER_TASKRUN` for minimal kernel overhead
- **Provided buffer ring** for zero-copy multishot receives -- the kernel writes directly into pre-registered buffers
- **Connection pool** -- each thread manages `connections / threads` TCP connections

### I/O flow

1. **Connect** -- async `io_uring_prep_connect` for non-blocking TCP setup
2. **Send** -- pipelined requests are pre-built into a single buffer and sent with `io_uring_prep_send`
3. **Receive** -- multishot `io_uring_prep_recv_multishot` with provided buffers; a single SQE produces multiple CQEs as data arrives
4. **Parse** -- a streaming HTTP response parser counts completed responses and extracts headers
5. **Refill** -- as responses complete, new requests are fired to maintain pipeline depth

### CQE batching

gcannon processes completions in batches using `io_uring_peek_batch_cqe`. With `DEFER_TASKRUN`, SEND and RECV completions can arrive in the same batch, which requires careful handling to avoid pipeline stalls.

## Request templates

gcannon supports two modes:

### URL mode
When given a plain URL (e.g., `http://host:8080/pipeline`), gcannon generates a standard HTTP/1.1 GET request and replicates it N times for pipelining.

### Raw template mode (`--raw`)
When given raw request files (e.g., `--raw get.raw,post_cl.raw,post_chunked.raw`), gcannon sends the exact bytes from each file. This enables:

- Mixed GET/POST workloads
- Requests with specific headers, body encodings, or query parameters
- Bit-perfect request reproduction

Templates are assigned round-robin to connections, so each connection sends one request type consistently.

### Dynamic placeholders

Raw templates support per-request value substitution via two placeholder types:

**`{RAND:min:max}`** - replaced with a random number between `min` and `max` (inclusive) on every request. Uses a per-connection xorshift64 PRNG with no cross-thread contention. Ideal for distributing reads and writes across a large ID space.

```http
GET /items/{RAND:1:100000} HTTP/1.1
Host: localhost:8080

```

**`{SEQ:start}`** - replaced with a globally incrementing counter starting at `start`. Uses a shared atomic counter across all threads, so every request gets a unique value. Ideal for INSERT operations where each row needs a distinct ID.

```http
POST /items HTTP/1.1
Host: localhost:8080
Content-Type: application/json
Content-Length: 72

{"id":{SEQ:100001},"name":"Bench","category":"test","price":100,"qty":50}
```

Values are **zero-padded** to the digit width of the max value, so the substituted buffer is always the same length as the original placeholder. This means `Content-Length` stays correct for POST/PUT bodies without recalculation.

One placeholder per template (the first `{RAND:` or `{SEQ:` found). Each template gets its own independent counter/RNG state. A per-connection scratch buffer is used for substitution - the shared template buffer is never modified.

## Pipelining

With `-p N`, gcannon sends N requests in a single write operation. As responses arrive, it refills the pipeline proportionally -- if 5 responses are received, 5 new requests are queued. This maintains steady pressure without overwhelming the server's receive buffer.

## Latency measurement

Latency is measured per-request from the moment the send SQE is prepared (not when the kernel completes the send) to when the corresponding response is fully parsed. This captures the true round-trip time as seen by the application.

For pipelined requests, each request in the batch gets its own send timestamp, and latencies are matched FIFO to response completions.

## Fixed-rate mode (`--rate`, gcannon ≥ 0.8.1)

Everywhere else gcannon sends the next request the moment the last response arrives. With `--rate N` it holds a fixed total rate instead, which is how [CON-5M and CON-1M-TLS](/docs/test-profiles/h1/connections/implementation/) run, plaintext and over TLS:

- every connection has its own schedule, one request per (connections / rate) seconds, the first offset by its share of the interval so the fleet sends evenly rather than in waves. Each thread spreads its connections over the whole interval, interleaved with the other threads. 0.8.0 gave each thread one contiguous slice instead, so one thread at a time sent the whole rate, and above what one thread can send its latency figures measured gcannon (p50 ~150 ms at a million connections); 0.8.1 fixes it;
- latency counts from each request's scheduled time (coordinated-omission correction), so a stall is charged to every request scheduled during it, not only to those already on the wire;
- the event loop sleeps exactly until the next send is due, with 1 ns timer slack, so sends leave within tens of microseconds of their slot; at the same paced load it reads the same p50-p99 as [zrk](../zrk/);
- one process holds five million connections in ~16 GiB (~3.3 KiB each), where zrk 2.3.0 needs ~303 KiB per connection and 3.0.2 ~41 KiB ([CON-1M](/docs/test-profiles/h1/connections/implementation/#con-1m-a-million-on-zrk) runs a million on it). Over TLS (`https://`), each connection handshakes TLS 1.3 with OpenSSL and is then handed to kernel TLS, and gcannon frees its own TLS state, so a held TLS connection costs it about what a plaintext one does.

Three options make a fleet that large possible: `--addr-span 160` spreads it over `127.0.0.1`-`127.0.0.160` (one source address holds ~64.5K connections to one destination), `--connect-limit` caps first connects in flight per thread so five million SYNs never land at once, and `--warmup-max` lets the warmup wait long enough for all of them to open. `--settle` (gcannon ≥ 0.8.2) then keeps the load running before the window opens, so the server has worked off the connect phase by the time measuring starts; CON-5M settles for 30s. On stderr it marks the window's start and end (`gcannon: warmup done ...`, `gcannon: measurement done`), which `scripts/conn_hold.py` uses to read the server's CPU over exactly that window.

## Command-line reference

```
Usage: gcannon <url> -c <conns> -t <threads> -d <duration>
              [-p <pipeline>] [-r <req/conn>]
              [-R|--raw file1,file2,...]
```

| Flag | Description | Default |
|------|-------------|---------|
| `-c` | Total connections | required |
| `-t` | Worker threads | required |
| `-d` | Test duration (e.g., `5s`, `30s`) | required |
| `-p` | Pipeline depth | 1 |
| `-r` | Requests per connection (0 = unlimited) | 0 |
| `--raw` | Comma-separated raw request template files | -- |
| `--rate` | Fixed total request rate (req/s), paced per connection; needs `-p 1`, no `-r` | closed loop |
| `--addr-span` | Spread connections over N consecutive IPv4 addresses from the target's | 1 |
| `--connect-limit` | First connects in flight per thread | all at once |
| `--warmup-max` | Longest the warmup waits for connections to open | 10s |
