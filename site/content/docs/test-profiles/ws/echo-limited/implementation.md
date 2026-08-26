---
title: Implementation Guidelines
seo_title: "Short-lived WebSocket Connection Benchmark: Implementation Guide"
description: "Endpoint contract and rules for the short-lived WebSocket profile, where each connection is retired after 10 echo messages and re-upgraded."
---
{{< type-rules standard="Must use the framework standard WebSocket API with default buffer sizes. The upgrade handshake must be handled by the framework's own WebSocket support - pre-computing or caching the 101 response across connections is not allowed." tuned="May optimize the upgrade path, frame handling and buffer sizes, including custom handshake parsing, as long as every connection performs a real handshake." engine="No specific rules. Ranked separately from frameworks." >}}


The endpoint is exactly the one used by [Echo](../echo/implementation/): `/ws` on port 8080, echoing each text frame back unchanged. The difference is entirely in the client: the load generator sends 10 messages per connection, then closes it and opens a replacement.

**Connections:** 512, 4,096
**Messages per connection:** 10
**Pipeline:** 1 (one message in flight at a time)

## Workload

1. Open a TCP connection to port 8080
2. Send an HTTP/1.1 upgrade request to `/ws`
3. After `101 Switching Protocols`, switch to WebSocket framing
4. Send a text frame containing `"hello"`, read the echo, repeat 10 times
5. Close the connection and return to step 1
6. Measure echoes received per second

Throughput is counted the same way as the other WebSocket profiles: one echo received is one completed response. The upgrade itself is not counted as a response, so a framework with a slow handshake shows up as lower echo throughput rather than as inflated numbers.

## What it measures

- Cost of the WebSocket upgrade handshake: request parsing, `Sec-WebSocket-Accept` computation, and the 101 response
- Per-connection setup and teardown: allocation of the connection's buffers and WebSocket state, and how promptly they are released
- Accept-path throughput under continuous connection churn, rather than the steady-state frame loop the other WebSocket profiles measure

A framework that performs well on [Echo](../echo/) but poorly here is spending its time in connection setup, not in frame handling.

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

`Sec-WebSocket-Accept` must be computed per connection from the client's `Sec-WebSocket-Key` as defined in [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455#section-4.2.2). Because this profile establishes a new connection every 10 messages, a server that returns a fixed, precomputed accept value would fail the handshake for every connection after the first.

## Notes

- No server-side changes are needed beyond the existing `/ws` endpoint. A framework already subscribed to `echo-ws` implements everything this profile requires.
- Closing is driven by the client. The server should honour the close handshake, but a framework that simply observes the TCP FIN is not penalized.
