---
title: Implementation Guidelines
seo_title: "8Gbit Benchmark: Implementation Guide"
description: "Endpoint contract, framing rules, parameters and scoring for the 10 KB TLS echo profile."
---
{{< type-rules standard="Must read the request body through the framework's standard body API and write it back through the standard response API. Streaming is allowed and encouraged. What is not allowed is answering without reading: a response assembled from Content-Length, or a canned buffer of the right size, is not an echo." tuned="May stream, use vectored writes, reuse buffers, or hand the bytes back with zero copies. The body must still be the bytes that arrived - the profile is defined by what comes back, not by how it is moved." engine="Same as above. An engine is free to splice or reuse the receive buffer directly for the response; that is the point of the profile." infrastructure="A proxy may stream the body through to an origin and back, or echo it itself. Either way the bytes returned must be the bytes sent." >}}


A 10 KB body is posted over TLS and must come back verbatim, so one request loads the read path, the write path and the TLS record layer **in both directions**. The rate is pinned rather than open-loop, so what varies between entries is what serving it cost, not how fast they went.

**Endpoint:** `POST /echo` · **Port:** `8081` (TLS, ALPN `http/1.1`) · **Body:** 10 KB · **Connections:** 512 · **Offered rate:** 50,000 req/s

## The contract

```
POST /echo HTTP/1.1
Content-Type: application/octet-stream
Content-Length: 10240

<10240 bytes>
```

The response is those bytes, unchanged:

```
HTTP/1.1 200 OK
Content-Type: application/octet-stream
Content-Length: 10240

<the same 10240 bytes>
```

The route is named `/echo` rather than after the profile, so a later profile can drive it at another size or framing without a second route to implement.

## Framing

The benchmark sends `Content-Length`, but **chunked must work too**. [Validation](../validation/) posts a chunked body at 10 KB and at 100 KB and requires it echoed byte-for-byte, so an implementation that takes the body length from `Content-Length` instead of from the framing will pass the benchmark and fail validation.

Sizes other than 10 KB must work as well: validation runs 1 B, 1 KB, 10 KB, 100 KB and an empty body.

## It has to be a real echo

The generator sends one constant body, so the benchmark run cannot by itself catch a cached response or one sized from `Content-Length` without reading. [Validation](../validation/) is the guard, and it posts **random** bodies compared byte for byte. Answering without reading is not penalised there, it fails.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `POST /echo` |
| Port | 8081 (TLS, ALPN `http/1.1`) |
| Body | 10 KB (10,240 bytes), `application/octet-stream` |
| Framing | `Content-Length` both ways |
| Connections | 512 |
| Offered rate | 50,000 req/s (`ZRK_RATE_8GBIT`) |
| Duration | 5s |
| Runs | 3, best kept |
| Load generator | [zrk](/docs/load-generators/h1/zrk/) - paced, `-m POST -b @<body>` |
| Metrics | rps, `rate_ratio`, latency (p50/p99/p99.9), CPU per request, memory |

## Scoring

Scored on cost rather than throughput: the rate is pinned, so every entry that holds it returns the same rps.

```
rateFactor = min(1, achieved_rps / 47,500)
quality    = 0.60 x cpuScore + 0.25 x p99Score + 0.15 x p999Score
score      = 100 x rateFactor x quality
```

Full credit at 47,500 req/s, 95% of the rate offered - the generator never quite reaches its own target. An entry that does not hold the rate is cut proportionally, so a run that was never offered the load it claims cannot score as though it were.

Same formula as [Latency-1M](../latency-1m/implementation/#scoring) and [Latency-10K](../latency-10k/implementation/#scoring), and computed by [`scripts/latency_score.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/latency_score.py).
