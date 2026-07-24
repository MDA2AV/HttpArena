---
title: gcannon
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
