---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework standard WebSocket API with default buffer sizes. No custom batching or read-ahead optimizations." tuned="May optimize WebSocket frame handling, buffer sizes, and use custom frame parsers or batched read paths." engine="No specific rules. Ranked separately from frameworks." >}}


Measures WebSocket echo throughput with pipelining. Each connection upgrades via HTTP/1.1, then sends 16 text messages back-to-back before waiting for the echoes. Each echo counts as one completed response.

**Connections:** 512, 4,096, 16,384
**Pipeline:** 16 (16 messages in flight per connection — send batch, drain echoes, repeat)

## Workload

1. Open TCP connection to port 8080
2. Send HTTP/1.1 upgrade request to `/ws`
3. After receiving `101 Switching Protocols`, switch to WebSocket framing
4. Send 16 text frames containing `"hello"` back-to-back, then read 16 echo frames
5. Measure messages per second

## What it measures

- WebSocket frame parsing efficiency under burst load
- Frameworks that drain multiple frames from a single read buffer gain a major advantage
- Frameworks processing one frame at a time per connection see minimal improvement over the non-pipelined echo
- Write coalescing and syscall reduction on the send path

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
| Pipeline | 16 (16 messages in flight per connection) |
| Message | `"hello"` (5 bytes, text frame) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | gcannon `--ws -p 16` |
