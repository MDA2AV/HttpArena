---
title: wrk
seo_title: "wrk: TLS Static File and JSON Load Generator"
description: "HttpArena uses wrk with Lua scripts to rotate across URIs over HTTP/1.1 + TLS for the static-tls and json-tls profiles."
---

[wrk](https://github.com/wg/wrk) is a multi-threaded HTTP benchmarking tool used for the two URI-rotating HTTP/1.1 + TLS profiles: **`static-tls`** and **`json-tls`**. Both run against port 8081.

## Why wrk for these profiles?

Both profiles run over TLS, and gcannon speaks plaintext HTTP/1.1 only. wrk handles TLS itself and rotates URIs with a small Lua script.

For the static files there is a second reason. The 20 files have response sizes from 3 KB to 67 KB (brotli-compressed). At these sizes, gcannon's io_uring provided buffer ring path introduces per-completion overhead that limits throughput to ~14 GB/s on loopback. wrk's simpler epoll + `read()` approach achieves ~19 GB/s on the same workload, ensuring the load generator is never the bottleneck.

For small-response plaintext tests (baseline, pipelined, JSON compression), gcannon's io_uring batched submission is faster than wrk. The tools complement each other.

## Lua rotation scripts

| Script | Profile | What it rotates |
|---|---|---|
| `requests/static-rotate.lua` | `static-tls` | All 20 static file paths, each request with `Accept-Encoding: br;q=1, gzip;q=0.8` |
| `requests/json-tls-rotate.lua` | `json-tls` | Seven `/json/{count}?m={m}` pairs, no `Accept-Encoding` |

The static rotation looks like this:

```lua
request = function()
  counter = counter + 1
  local path = paths[((counter - 1) % 20) + 1]
  return wrk.format("GET", path, {["Accept-Encoding"] = ae_header})
end
```

## Latency

wrk prints average and maximum latency but no percentiles unless run with `--latency`. The harness records wrk's **maximum** latency in the p99 column for these two profiles, so read it as a worst case rather than a percentile.

## Parameters

| Parameter | Value |
|-----------|-------|
| Test profiles | `static-tls`, `json-tls` |
| Port | 8081 (HTTP/1.1 over TLS) |
| Threads | 64 |
| Connections | 1,024 (`static-tls`), 4,096 (`json-tls`) |
| Duration | 5s |
| Runs | 3 (best taken) |
