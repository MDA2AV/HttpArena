---
title: wrk
---

[wrk](https://github.com/wg/wrk) is a multi-threaded HTTP benchmarking tool used for the **static file serving** test profile.

## Why wrk for static files?

The static file test serves 20 files with response sizes ranging from 3 KB to 67 KB (brotli-compressed). At these sizes, gcannon's io_uring provided buffer ring path introduces per-completion overhead that limits throughput to ~14 GB/s on loopback. wrk's simpler epoll + `read()` approach achieves ~19 GB/s on the same workload, ensuring the load generator is never the bottleneck.

For small-response tests (baseline, JSON, pipelined), gcannon's io_uring batched submission is faster than wrk. The tools complement each other.

## Lua rotation script

wrk uses a Lua script (`requests/static-rotate.lua`) to cycle through all 20 static file paths. Each request includes `Accept-Encoding: br;q=1, gzip;q=0.8` to test compressed file serving.

```lua
request = function()
  counter = counter + 1
  local path = paths[((counter - 1) % 20) + 1]
  return wrk.format("GET", path, {["Accept-Encoding"] = ae_header})
end
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Test profiles | `static` |
| Threads | 64 |
| Connections | 1,024, 4,096, 6,800 |
| Duration | 5s |
| Runs | 3 (best taken) |
