---
title: Validation
seo_title: "WebSocket Echo Benchmark: Validation Checks"
description: "The correctness checks validate.sh runs against the WebSocket echo benchmark before a framework's results are accepted."
---

The following checks are executed by `validate-ws.py` for every framework subscribed to the `echo-ws` test. The script uses a raw socket WebSocket client with no external dependencies.

## Upgrade handshake (101 status)

Sends an HTTP/1.1 WebSocket upgrade request to `/ws` with a random `Sec-WebSocket-Key`. Verifies the server responds with **HTTP 101 Switching Protocols**.

## Sec-WebSocket-Accept header

Verifies the server returns a correct `Sec-WebSocket-Accept` value, computed as `Base64(SHA-1(key + "258EAFA5-E914-47DA-95CA-5BAB11DC85B6"))` per RFC 6455.

## Text echo

Sends a text frame containing a random string (`HttpArena-validate-{random_hex}`) and verifies the server echoes back the exact same text in a text frame (opcode 0x1).

## Binary echo

Sends a binary frame containing 256 random bytes and verifies the server echoes back the exact same bytes in a binary frame (opcode 0x2).

## Multi-message echo

Sends 5 text frames rapidly in sequence, each with a unique random payload. Verifies all 5 are echoed back in order with correct content. This tests message ordering and buffering under burst conditions.

## Clean close

Sends a close frame with code 1000 (normal closure) and reason `"validate done"`. Verifies the server responds with a close frame containing code 1000.

## Reject non-upgrade request

Sends a regular `GET /ws` request (without WebSocket upgrade headers) and verifies the server returns a **4xx status code** (400 or 426), not 101 or 5xx. The server must not crash on non-WebSocket requests to the WebSocket endpoint.

## Post-validation health check

After all tests complete, opens a new WebSocket connection, sends a text frame `"health"`, verifies the echo, and performs a clean close. This confirms the server is still alive and functioning correctly after handling the full validation suite.
