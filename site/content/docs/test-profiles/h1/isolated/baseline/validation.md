---
title: Validation
seo_title: "Baseline Throughput Benchmark: Validation Checks"
description: "The correctness checks validate.sh runs against the HTTP/1.1 baseline throughput benchmark before a framework's results are accepted."
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
- **POST lower-cased field names** - the same POST, spelled `host:`, `content-type:`, `content-length:`, `connection:`. HTTP field names are case-insensitive (RFC 9110 §5.1), so a parser that only matches `Content-Length` would not find the body length. Only meaningful over HTTP/1.1 - HTTP/2 and HTTP/3 mandate lowercase on the wire. Expects body `75`.

## Exhaustive TCP fragmentation

The splits above land where a person chose to put them, which only covers the boundaries someone thought of. This check sweeps **every** one: `validate-frag.py` takes nine request shapes and splits each at every byte offset - roughly 1,000 in total - then requires HTTP 200 with the exact expected body on all of them.

For each offset it opens a connection, writes the first part, pauses **200 ms**, writes the rest, and reads to EOF. The pause is the substance of the test: it guarantees the server's read loop returns holding a partial request and has to carry parser state across `recv()` calls, rather than the kernel coalescing both writes into one segment. Connections are opened in batches of 384 and each batch pays the pause once, so the whole sweep runs in about two seconds.

Every shape carries a `?a=…&b=…` query string, so query parsing sits on the split path too - not just the request line and headers.

The nine shapes:

| Shape | Expected |
|---|---|
| `GET`, minimal headers | `55` |
| `GET`, several headers (`User-Agent`, `Accept`, `Accept-Encoding`) | `55` |
| `GET`, lower-cased field names | `55` |
| `GET`, randomized `a` and `b` | `a + b` |
| `POST`, `Content-Length` body | `75` |
| `POST`, lower-cased `content-length` | `75` |
| `POST`, randomized query and body | `a + b + body` |
| `POST`, chunked body in one chunk | `75` |
| `POST`, chunked body in two chunks | `75` |

Two of the shapes randomize their operands, so a hardcoded or cached response fails here as well as in the anti-cheat checks above.

The offsets that matter are the ones nobody picks by hand: between the `\r` and the `\n` of a header line, midway through the `Content-Length` digits, inside the chunk-size hex, and one byte into the terminating `0\r\n\r\n`. The chunked shapes are the only place in the suite where a chunked body is fragmented at all - the chunked check above sends its request through curl in a single write, and the hand-picked splits only ever fragment `Content-Length` bodies.

The approach is borrowed from [uWebSockets' `fragment_test.ts`](https://github.com/uNetworking/uWebSockets/blob/master/tests/fragment_test.ts), which does the same byte-by-byte sweep. Two differences here: the response body is asserted rather than just the status code, since a server can answer `200` with the wrong sum; and connections are batched so one pause covers a batch instead of one offset.
