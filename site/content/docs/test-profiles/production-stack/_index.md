---
weight: 5
title: Production Stack
---

The Production Stack profile benchmarks a **realistic multi-service CRUD API deployment** — reverse proxy, JWT auth sidecar, Redis cache, application server, and Postgres database — with a 10,000-item working set that exercises a real three-tier cache hierarchy (L1 in-process → L2 Redis → Postgres) under authenticated load.

This is the closest any HttpArena test comes to modeling real production traffic:

- **JWT authentication on every API call** — a shared Rust sidecar verifies HMAC-SHA256 signatures with no caching. Real cryptographic work on every request, not a cached lookup.
- **Cache-aside required** — frameworks must implement cache-aside on reads (check cache → miss → DB → populate) and invalidation on writes. How the caching works (in-process, Redis, two-tier, framework-native) is the framework's choice — the cache strategy is part of the competition.
- **Cache-aside with short TTL** — items cached ≤1 second so the cache constantly cycles: L1 hits → L2 (Redis) hits → Postgres queries → populate both layers. 10K unique IDs mean the cache hierarchy is under real pressure, not permanently warm.
- **CRUD writes** — POST requests parse a JSON body, UPDATE in Postgres, and invalidate both cache layers. Reads and writes target overlapping IDs to create realistic cache churn.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Four-service compose, JWT auth contract, HybridCache rules, cache-aside pattern, endpoint specs, CPU allocation." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="15 checks: auth wall (4), cache-aside cycle, POST invalidation, user lookup chain." icon="check-circle" >}}
{{< /cards >}}
