---
title: Implementation Guidelines
seo_title: "Unary gRPC Benchmark: Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the unary gRPC benchmark."
---
{{< type-rules standard="Must use the standard gRPC library for the language with default configuration. No custom protobuf serialization." tuned="May optimize gRPC channel settings, thread pools, and use custom protobuf serialization." engine="No specific rules. Ranked separately from frameworks." >}}


Measures unary gRPC call throughput over cleartext HTTP/2 (h2c). The server implements a simple `GetSum` RPC that adds two integers.

**Connections:** 256, 1,024
**Concurrent streams per connection:** 100

## Proto definition

```protobuf
syntax = "proto3";
package benchmark;

service BenchmarkService {
  rpc GetSum (SumRequest) returns (SumReply);
}

message SumRequest {
  int32 a = 1;
  int32 b = 2;
}

message SumReply {
  int32 result = 1;
}
```

## Workload

`POST /benchmark.BenchmarkService/GetSum` sent as a gRPC unary call over h2c. The load generator ([h2load](https://nghttp2.org/documentation/h2load-howto.html)) sends pre-encoded protobuf frames with gRPC headers (`content-type: application/grpc`, `te: trailers`).

The request payload is a 9-byte gRPC frame: 5-byte frame header + 4-byte protobuf-encoded `SumRequest{a=1, b=2}`.

## What it measures

- gRPC/HTTP2 frame processing overhead
- Protocol Buffers serialization/deserialization performance
- HTTP/2 stream multiplexing efficiency for gRPC
- Server-side gRPC service dispatch latency

## Expected request/response

```
POST /benchmark.BenchmarkService/GetSum HTTP/2
content-type: application/grpc
te: trailers

<binary: 00 00000004 08011002>
```

```
HTTP/2 200 OK
content-type: application/grpc

<binary: 00 00000002 0803>

grpc-status: 0
```

## How it differs from HTTP/2 baseline

| | Baseline (HTTP/2) | Unary (gRPC) |
|---|---|---|
| Protocol | HTTP/2 over TLS | gRPC over h2c |
| Serialization | Plain text | Protocol Buffers |
| Port | 8443 | 8080 |
| Request method | GET | POST |
| Load generator | h2load | h2load (raw gRPC frames) |

## Parameters

| Parameter | Value |
|-----------|-------|
| RPC | `BenchmarkService/GetSum` |
| Connections | 256, 1,024 |
| Streams per connection | 100 (`-m 100`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load |
