---
title: Implementation Guidelines
---
{{< type-rules production="All endpoint implementations must follow their respective production rules. No endpoint-specific optimizations that would not be used in production." tuned="May optimize each endpoint independently. Custom serializers and non-default configurations allowed. Pre-computed / pre-serialized JSON response caches are not allowed on either type — the JSON slice of this workload must still be serialized per request from live data." engine="No specific rules." >}}

The API-4 profile runs a multi-endpoint workload with the server container constrained to **4 CPUs and 16 GB memory**. Only baseline, JSON, and async database endpoints are tested. The load generator uses 64 threads and 256 connections.

**Connections:** 256

## Configuration

| Parameter | Value |
|-----------|-------|
| Server CPUs | 4 (cpuset 0-3) |
| Server memory | 16 GB |
| Connections | 256 |
| gcannon threads | 64 |
| Duration | 15s |
| Request templates | 8 (3 baseline, 3 JSON, 2 async-db) |
| Requests per connection | 5 (then reconnect) |

## What it measures

- **Resource-constrained performance** - how well a framework utilizes limited CPU and memory
- **Real-world relevance** - closer to a typical production deployment (4-core VM, limited RAM) than the full-hardware tests
- **Efficiency under contention** - thread pool saturation, memory pressure, and GC behavior when resources are scarce
- **Scaling characteristics** - whether a framework's performance degrades gracefully with fewer resources

## Request mix

- 3x baseline GET (`GET /baseline11?a=1&b=2`)
- 3x JSON processing (`GET /json`)
- 2x async DB query (`GET /async-db?min=10&max=50`)

## Docker constraints

The server container is started with:

```
--cpuset-cpus=0-3 --memory=16g --memory-swap=16g
```

If a framework exceeds the 16 GB memory limit, the container will be OOM-killed by Docker.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoints | `/baseline11`, `/json`, `/async-db` |
| Connections | 256 |
| Pipeline | 1 |
| Requests per connection | 5 (then reconnect with next template) |
| Duration | 15s |
| Runs | 3 (best taken) |
| Templates | 8 (3 baseline GET, 3 JSON, 2 async-db) |
| Server CPU limit | 4 |
| Server memory limit | 16 GB |
| gcannon threads | 64 |
