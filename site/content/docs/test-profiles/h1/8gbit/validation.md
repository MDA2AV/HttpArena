---
title: Validation
seo_title: "8Gbit Benchmark: Validation Checks"
description: "The byte-exact echo checks validate.sh runs against POST /echo, including the chunked probe, before a framework's results are accepted."
---

Every check is **byte-exact**. The profile is an echo, so what has to be established is that the bytes come back unchanged - not that a length or a count matches.

| Check | What it establishes |
|---|---|
| `POST /echo` with a 1-byte random body | the smallest possible body round-trips |
| `POST /echo` with a 1 KB random body | ordinary case |
| `POST /echo` with a 10 KB random body | the benchmark's own size |
| `POST /echo` with a 100 KB random body | a body larger than the benchmark uses, spanning several TLS records and socket buffers |
| `POST /echo` with a **chunked** body | the body is read from the chunked framing, not from a `Content-Length` |
| `POST /echo` with an empty body | 200 with an empty response, not a 411 or a hang |
| [Shared TLS checks](../../json-tls/validation/#tls-checks) on `:8081` | the mounted certificate, TLS 1.3 with an AEAD cipher, ALPN `http/1.1` |

**The bodies are random,** and that is deliberate. A fixed body can be answered from a canned response without ever reading the request. The benchmark itself posts a single constant body, so these checks are what make answering without reading impossible.

Every probe is sent with `--http1.1`. Port 8081 may also advertise `h2`, and an echo that is broken over HTTP/1.1 can still pass over HTTP/2 - the benchmark only speaks HTTP/1.1, so that is what is validated.

**The chunked probe is the one the old Upload profile never had.** Every one of its checks sent a body with an accurate `Content-Length` and compared the returned byte count, so a handler that echoed that header without reading a single body byte passed the entire suite - and would have outranked one that actually did the work.
