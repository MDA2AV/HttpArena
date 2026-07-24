---
title: ghz
---

[ghz](https://ghz.sh/) is a proto-aware gRPC load testing tool written in Go. HttpArena uses it to drive the `stream-grpc` and `stream-grpc-tls` profiles. Unlike h2load (which ships pre-serialized binary bodies as raw HTTP/2 DATA frames), ghz is a full gRPC client - it parses the `.proto` file at runtime, marshals requests into protobuf, and issues actual gRPC calls of the correct shape (unary, server-streaming, client-streaming, or bidi) based on the method's proto definition.

## Installation

```bash
go install github.com/bojand/ghz/cmd/ghz@latest
```

The binary ends up in `$GOPATH/bin/ghz`. Ensure it's on `$PATH` or move it to `/usr/local/bin/`. HttpArena respects the `GHZ` environment variable (`GHZ="${GHZ:-ghz}"` in `benchmark.sh`), so `GHZ=/custom/path/ghz ./scripts/benchmark.sh ...` also works.

## How it's used

### Server-streaming throughput (`stream-grpc`)

```bash
ghz --insecure --proto requests/benchmark.proto \
    --call benchmark.BenchmarkService/StreamSum \
    -d '{"a":1,"b":2,"count":5000}' \
    --connections 64 -c 256 -z 5s \
    localhost:8080
```

### Server-streaming over TLS (`stream-grpc-tls`)

```bash
ghz --skipTLS --proto requests/benchmark.proto \
    --call benchmark.BenchmarkService/StreamSum \
    -d '{"a":1,"b":2,"count":5000}' \
    --connections 64 -c 256 -z 5s \
    localhost:8443
```

| Flag | Description | Value |
|------|-------------|-------|
| `--insecure` | Plaintext h2c - no TLS at all | for `stream-grpc` |
| `--skipTLS` | TLS with server cert verification disabled | for `stream-grpc-tls` |
| `--proto` | Path to canonical `benchmark.proto` | `requests/benchmark.proto` |
| `--call` | Fully-qualified method name | `benchmark.BenchmarkService/StreamSum` |
| `-d` | JSON request payload (marshaled to protobuf) | `{"a":1,"b":2,"count":5000}` |
| `--connections` | Number of TCP connections | 64 |
| `-c` | Number of concurrent worker goroutines | 256 (4 streams per TCP connection) |
| `-z` | Benchmark duration | 5s |

The ratio of `--connections` to `-c` controls stream multiplexing. `64 × 256` means each TCP connection carries an average of 4 concurrent streams via HTTP/2 - empirically the optimal shape under TLS with 5000 msgs/call: ~8.6M msgs/sec peak with under 2% error rate and ~145 ms average latency. Denser ratios (8:1 or 16:1) push throughput slightly higher on paper but the error rate explodes to 10-30% as Kestrel's HTTP/2 flow-control windows and per-connection write loops start shedding streams under pressure.

## How the number is reported

ghz's text output has the shape:
```
Summary:
  Count:        2500
  Total:        5.00 s
  Slowest:      89.3 ms
  Fastest:      4.1 ms
  Average:      37.6 ms
  Requests/sec: 500.00
```

For server-streaming calls, **`Requests/sec` is calls per second, not messages per second**. HttpArena multiplies it by the messages-per-call constant (`5000` for the current profiles) to arrive at the headline **messages/sec** figure shown on the leaderboard. That way streaming throughput is directly comparable to unary calls/sec - both represent "protobuf messages delivered through the framework per second."

## Why ghz and not h2load for streaming

h2load cannot generate gRPC streams at all. It only knows how to send opaque HTTP/2 DATA frames with a pre-built body - it has no concept of reading a response stream, let alone distinguishing a server-streaming call from a unary one. For the existing `unary-grpc` profile h2load works fine because each call is a single request/response; for anything where the shape matters, you need a real gRPC client. ghz's overhead (protobuf marshal on every call) means its unary throughput is ~50× lower than h2load's raw-wire throughput, but that's the honest gRPC number - the h2load unary-grpc figure is actually a raw h2-frame-throughput measurement, not a gRPC client/server round-trip.

## Limitations

- **Unary throughput caps around ~47k req/sec** on our test hardware due to grpc-go client-side overhead. h2load still wins for unary-only raw throughput - but `stream-grpc` is where ghz shines, reaching 6M+ msg/sec because the per-call cost amortizes over thousands of messages.
- **ghz does not measure per-message latency** inside a stream - only call-level latency (time from stream open to stream close). For per-message latency you'd need a custom client.
- **No built-in warm-up phase** - first few calls may include TLS handshakes and channel setup. The 5-second default duration is long enough that handshake cost rounds out.
- **Client-streaming and bidi** work in ghz (`-d` accepts a JSON array of messages), but HttpArena doesn't currently use them - they measure round-trip latency more than framework throughput.
