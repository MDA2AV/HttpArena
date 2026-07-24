---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `baseline` or `limited-conn` test.

## GET with query parameters

Sends `GET /baseline11?a=13&b=42` and verifies the response body is `55` (sum of `a` and `b`).

## POST with Content-Length body

Sends `POST /baseline11?a=13&b=42` with body `20` and `Content-Type: text/plain`. Verifies the response body is `75` (sum of `a`, `b`, and body).

## POST with chunked Transfer-Encoding

Sends `POST /baseline11?a=13&b=42` with body `20` and `Transfer-Encoding: chunked`. Verifies the response body is `75`.

## Anti-cheat: randomized query parameters

Generates random values for `a` and `b` (100-999), sends `GET /baseline11?a={a}&b={b}`, and verifies the response matches the expected sum. This detects hardcoded responses.

## Anti-cheat: POST body cache detection

Sends two POST requests with different random body values to the same endpoint (`/baseline11?a=13&b=42`). Verifies each response reflects the correct sum for that specific body. This detects response caching or hardcoded POST handling.

- Request 1: body=`{random1}` - expects `13 + 42 + random1`
- Request 2: body=`{random2}` - expects `13 + 42 + random2`

## TCP fragmentation

Each request below is sent over a raw TCP socket (`TCP_NODELAY`, no Nagle coalescing) in multiple `sendall()` writes with a 30 ms pause between fragments. Every framework's HTTP parser must reassemble these partial reads and produce the correct response. Simulates realistic network behavior - slow clients, small MTU, intermediate proxies that chunk data.

Every fragmented request sets `Connection: close` so the server closes the socket after the response and the test can read until EOF.

- **Split request line** - the request line arrives in two halves (`"GET /baseli"` + `"ne11?a=13&b=42 HTTP/1.1\r\n…"`). The parser sees an incomplete method/path on the first `recv()`. Expects body `55`.
- **Split before headers** - the request line arrives in one write, then each header line arrives in its own write (`Host:`, `User-Agent:`, `Connection:`). Expects body `55`.
- **POST split headers/body** - the full header block (including terminating `\r\n\r\n`) is one write, then the body arrives in a separate write after the pause. Expects body `75`.
- **POST split body bytes** - headers in one write, then the 2-byte body (`"20"`) arrives as two 1-byte writes. Stresses the parser's ability to reassemble a Content-Length body across multiple `recv()` calls. Expects body `75`.
