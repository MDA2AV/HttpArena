---
title: Implementation Guidelines
---
{{< type-rules production="All endpoint implementations must follow their respective production rules. No endpoint-specific optimizations that would not be used in production." tuned="May optimize each endpoint independently. Custom serializers and non-default configurations allowed. Pre-computed / pre-serialized JSON response caches are not allowed on either type — the JSON slice of this workload must still be serialized per request from live data." engine="No specific rules." >}}

The API-16 profile is identical to [API-4](../../api-4/implementation) but with the server constrained to **16 CPUs and 32 GB memory** instead of 4 CPUs and 16 GB. This measures how well the framework scales with more available resources.

**Connections:** 1,024

All [request mix and implementation rules](../../api-4/implementation) from API-4 apply.

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
--cpuset-cpus=0-7,64-71 --memory=32g --memory-swap=32g
```

If a framework exceeds the 32 GB memory limit, the container will be OOM-killed by Docker.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoints | `/baseline11`, `/json`, `/async-db` |
| Connections | 1,024 |
| Pipeline | 1 |
| Requests per connection | 5 (then reconnect with next template) |
| Duration | 15s |
| Runs | 3 (best taken) |
| Templates | 8 (3 baseline GET, 3 JSON, 2 async-db) |
| Server CPU limit | 16 |
| Server memory limit | 32 GB |
| gcannon threads | 64 |
