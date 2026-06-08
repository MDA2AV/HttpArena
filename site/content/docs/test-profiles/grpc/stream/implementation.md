---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework's standard gRPC server implementation. No bypassing of protobuf serialization or HTTP/2 framing." tuned="May tune HTTP/2 frame sizes, flow-control window sizes, and server concurrency limits beyond defaults." engine="No specific rules. Ranked separately from frameworks." >}}

The Server Streaming profile measures how efficiently a framework can emit a stream of protobuf messages from a single server-streaming gRPC call. One unary-style request lands on the server, and the handler writes **N** replies to a single `IServerStreamWriter` (or equivalent) before completing the call. The load generator ([ghz](/docs/load-generators/grpc/ghz/)) opens many concurrent streams and sums the total messages delivered per second.

**Connections:** 64
**Streams per connection:** 4 (64 conns × 256 workers = 4-way stream multiplexing per conn)
**Messages per call:** 5,000

## How it works

1. Client issues `StreamSum(StreamRequest{ a, b, count: 5000 })` on a new HTTP/2 stream
2. Server responds with `count` `SumReply` messages, each carrying `result = a + b + i` for `i` in `0..count-1`
3. Client consumes all `count` replies before closing the stream and opening another call
4. ghz reports calls/sec; the benchmark runner multiplies by `msgs/call` and records messages/sec as the headline throughput

The shape rewards frameworks that amortize per-call overhead across many stream writes - a single call incurs one gRPC framing setup, one protobuf marshal of the request, and then a tight loop emitting replies through Kestrel's HTTP/2 frame writer (or the equivalent in other frameworks). Frameworks that do per-message context allocation or contention on a shared writer will lose ground.

## What it measures

- **Stream dispatch efficiency** - per-message cost inside a live HTTP/2 stream, not per-call cost
- **HTTP/2 frame writer throughput** - how fast the server can serialize protobuf messages into DATA frames
- **Flow-control handling** - with 4 concurrent streams per TCP connection, WINDOW_UPDATE frames must not stall the stream
- **Per-stream CPU efficiency** - a single stream runs on a single logical thread in most frameworks; scaling comes from many parallel streams

## Protobuf service

```protobuf
service BenchmarkService {
  rpc StreamSum (StreamRequest) returns (stream SumReply);
}

message StreamRequest {
  int32 a = 1;
  int32 b = 2;
  int32 count = 3;
}

message SumReply {
  int32 result = 1;
}
```

## Handler contract

For every incoming `StreamRequest`:
- Compute `sum = request.a + request.b`
- Loop `request.count` times emitting `SumReply { result: sum + i }` through the server-stream writer
- Clamp `count` to `>= 1` defensively (anti-crash only, the load gen always sends 5,000)

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `BenchmarkService/StreamSum` |
| Profiles | `stream-grpc` (h2c :8080) and `stream-grpc-tls` (h2 TLS :8443) |
| Connections | 64 |
| Concurrent workers | 256 (4 streams per TCP connection) |
| Messages per call | 5,000 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | [ghz](/docs/load-generators/grpc/ghz/) |
| Metric | Messages per second (calls/sec × msgs/call) |

## Why messages/sec instead of calls/sec

Streaming RPC calls are not comparable to unary calls on a per-call basis - a single server-streaming call can deliver thousands of messages through the framework's dispatch path. Reporting calls/sec would make a 100× msgs/call workload look 100× slower than unary even when the framework is actually pushing more aggregate protobuf work.

Messages/sec normalizes against unary throughput: for aspnet-grpc on this hardware, unary hits ~2.3M req/sec (via h2load) and server-streaming hits ~6M msg/sec (via ghz). The streaming number is ~3× the unary number because amortization more than compensates for the per-call overhead savings h2load gets by not doing real client-side gRPC work.

## Notes

- The streaming test does not subscribe to the `-r` request-per-conn rotation that gcannon-based profiles use - ghz's streaming model opens fresh calls continuously until the duration elapses
- Frameworks must return exactly `count` replies per call - validation checks `reply.length == count`
- Use of server-push or trailing-only responses to "fake" streaming is not allowed. Each reply must be a distinct gRPC DATA frame containing a valid `SumReply`.
