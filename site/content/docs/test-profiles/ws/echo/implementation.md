---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework standard WebSocket API with default buffer sizes." tuned="May optimize WebSocket frame handling, buffer sizes, and use custom frame parsers." engine="No specific rules. Ranked separately from frameworks." >}}


Measures WebSocket echo throughput. Each connection upgrades via HTTP/1.1, then sends text messages and receives echoes. Each echo counts as one completed response.

**Connections:** 512, 4,096, 16,384
**Pipeline:** 1 (one message in flight per connection — send, await echo, repeat)

## Workload

1. Open TCP connection to port 8080
2. Send HTTP/1.1 upgrade request to `/ws`
3. After receiving `101 Switching Protocols`, switch to WebSocket framing
4. Send text frames containing `"hello"`, receive echo frames
5. Measure messages per second

## What it measures

- WebSocket upgrade handshake performance
- WebSocket frame parsing and construction efficiency
- Echo round-trip latency under load
- Connection scalability for real-time workloads

## Expected upgrade request/response

```
GET /ws HTTP/1.1
Host: localhost:8080
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
```

```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `/ws` (WebSocket upgrade) |
| Connections | 512, 4,096, 16,384 |
| Pipeline | 1 (one message in flight per connection) |
| Message | `"hello"` (5 bytes, text frame) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | gcannon `--ws` |
