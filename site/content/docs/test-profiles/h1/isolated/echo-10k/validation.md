---
title: Validation
seo_title: "Echo-10K Benchmark: Validation Checks"
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
| TLS posture probe on `:8081` | ALPN negotiates `http/1.1` |

**The bodies are random,** and that is deliberate. A fixed body can be answered from a canned response without ever reading the request. The benchmark rotates eight distinct bodies for the same reason; these checks make answering-without-reading impossible rather than merely unlikely.

**The chunked probe is the one the old Upload profile never had.** Every one of its checks sent a body with an accurate `Content-Length` and compared the returned byte count, so a handler that echoed that header without reading a single body byte passed the entire suite - and would have outranked one that actually did the work.
