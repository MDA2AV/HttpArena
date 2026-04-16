---
title: Implementation Guidelines
weight: 1
---
{{< type-rules production="Must ship exactly four services: edge (reverse proxy), cache (Redis), authsvc (the shared JWT verifier from frameworks/_shared/authsvc/, built as-is), and server (the framework). No custom auth implementations — JWT verification must happen at the edge via auth_request / forward_auth using the shared authsvc. The framework must implement cache-aside on /api/items reads (check cache → miss → query DB → populate cache with ≤1 second TTL) and cache invalidation on /api/items writes (clear cache after DB update). How the caching is implemented is the framework's choice — any combination of in-process cache, Redis, or framework-specific cache abstraction is allowed." tuned="Same four-service shape as production. May tune proxy configuration, connection pools, CPU split, and cache TTLs. May NOT replace authsvc with a custom implementation or skip JWT verification." engine="No specific rules. May replace any service with a custom implementation. Ranked separately from frameworks." >}}

## Overview

The Production Stack test benchmarks a **realistic multi-service CRUD API deployment** as a unit. The load generator sends HTTPS/h2 requests to the edge. Request flow depends on the path:

| Path | Flow |
|---|---|
| `/static/*` | edge serves from disk (no auth, no backend) |
| `/public/*` | edge → server (no auth, no cache) |
| `/api/*` | edge → authsvc (JWT verification) → server (HybridCache L1 → Redis L2 → Postgres) |

## Architecture

Four services, plus the shared Postgres sidecar (external, managed by the benchmark script):

```
                  h2 + TLS
  ┌──────────┐   ─────────>    ┌─────────┐     auth_request        ┌──────────┐
  │  h2load  │   port 8443     │  edge   │  ──────────────────►   │ authsvc  │
  │          │                 │ (nginx) │                         │  (Rust)  │
  │          │   Authorization │         │  ◄── 200 + X-User-Id   │ JWT+HMAC │
  │          │   Bearer <jwt>  │         │                         └──────────┘
  └──────────┘                 │         │
                               │         │   /api/*
                               │         │   ────────────────►    ┌──────────┐
                               │         │   X-User-Id header     │  server  │
                               │         │                        │(framework│
                               │         │   /public/*            │          │
                               │         │   ────────────────►    │ L1 cache │
                               └─────────┘                        │ L2 Redis │
                                                                  │ Postgres │
                                                                  └────┬─────┘
                                                                       ▼
                                                                  ┌──────────┐
                                                                  │  cache   │
                                                                  │ (Redis)  │
                                                                  └──────────┘
```

## Authentication — JWT HMAC-SHA256

Every `/api/*` request carries an `Authorization: Bearer <jwt>` header. The edge proxy fires an `auth_request` subrequest to the shared authsvc sidecar on **every single API call** — no caching, no shortcuts. authsvc:

1. Reads the `Authorization: Bearer <token>` header
2. Splits the JWT into `header.payload.signature`
3. Computes `HMAC-SHA256(secret, header.payload)` and compares with the provided signature
4. Base64-decodes the payload and extracts the `sub` claim (user_id)
5. Returns `200 OK` with `X-User-Id: <user_id>` or `401 Unauthorized`

The JWT secret is shared between the token generator (`data/jwt-token.txt`) and authsvc via the `JWT_SECRET` environment variable. The pre-generated token embeds `{"sub":"42","name":"Alice Chen","exp":<future>}`.

**Key rules:**
- **Entries must use the shared authsvc binary unmodified.** The Rust sidecar at `frameworks/_shared/authsvc/` is the same for every framework entry. Do not reimplement JWT verification in the framework's language.
- **No auth caching at the edge.** No `proxy_cache` on the `/_auth` location. Every `/api/*` request must trigger a real HMAC-SHA256 verification. The CPU cost of this verification is part of what the test measures.
- **No auth logic in the framework.** The framework receives requests with a trusted `X-User-Id` header set by the edge after successful JWT verification. The framework never parses JWTs, never validates tokens, never touches the `Authorization` header.

## Caching

The framework must implement **cache-aside** on `/api/items` reads: check cache first, fall through to Postgres on miss, populate cache with a short TTL (≤1 second). On writes, the framework must invalidate the cache entry so the next read sees fresh data.

**How** the caching is implemented is entirely the framework's choice. Examples:

- **Two-tier L1+L2**: in-process memory cache + Redis (e.g. .NET HybridCache, Rails ActiveSupport::Cache with memory + Redis). Highest performance because hot keys never leave the process.
- **Redis-only**: every cache-aside read goes to Redis. Simpler but slower — Redis single-thread becomes the ceiling at high rps.
- **In-process only**: no Redis for caching, just a local hashmap with TTL. Works but loses the shared cache on multi-instance deployments.
- **Framework-native cache**: whatever the framework ships (Django cache, Spring Cache, etc.).

The .NET reference entry uses `HybridCache` (L1 in-process + L2 Redis) because that's the idiomatic .NET 9+ pattern. Other frameworks should use whatever caching approach is natural and documented for their ecosystem. The test measures how well the **framework + its cache choice** perform together — the cache strategy is part of the competition.

### Cache-aside pattern

`GET /api/items/{id}`:
1. Check L1 (in-process memory) by key `item:{id}`
2. L1 miss → check L2 (Redis via the distributed cache abstraction)
3. L2 miss → `SELECT ... FROM items WHERE id = $1` in Postgres
4. Populate both L1 and L2 with the result, TTL ≤ 1 second
5. Return JSON with `X-Cache: HIT` or `X-Cache: MISS` header

`POST /api/items/{id}`:
1. Parse JSON body (`name`, `price`, `quantity`)
2. `UPDATE items SET ... WHERE id = $1` in Postgres
3. Invalidate cache key `item:{id}` via the abstraction's `RemoveAsync` / equivalent (must clear both L1 and L2)
4. Return `204 No Content`

`GET /api/me`:
1. Read `X-User-Id` header (set by edge from authsvc JWT verification)
2. Cache-aside lookup on `user:{id}` with TTL ≤ 30 seconds
3. Miss → `SELECT id, name, email, plan FROM users WHERE id = $1`
4. Return user JSON

### Cache TTLs

| Cache key | L1 TTL | L2 TTL | Rationale |
|---|---|---|---|
| `item:{id}` | ≤ 1 second | ≤ 1 second | Short TTL so the cache constantly cycles and Postgres sees regular traffic. At 10K unique IDs and ~250K rps, each ID is read ~12×/sec → ~92% L1 hit rate with 1s TTL. |
| `user:{id}` | ≤ 30 seconds | ≤ 30 seconds | User profiles change rarely. Longer TTL means near-100% hit rate during a 5-second benchmark. |

### What the cache hierarchy looks like under load

With 10,000 unique item IDs at ~250K rps (50% items):

| Layer | Ops/sec | What it does |
|---|---|---|
| L1 (in-process memory) | ~115K hits | ~100 ns hashmap lookup |
| L2 (Redis) | ~5–10K | HMGET on L1 miss, ~50 µs |
| Postgres | ~5–10K | SELECT on L2 miss, ~200 µs |
| L2 writeback | ~5–10K | HMSET + EXPIRE on Postgres hit |

This is a real three-tier cache hierarchy under real load. Every layer does measurable work.

## Endpoint responsibilities

| Endpoint | Method | Auth | Cache | Database | What the framework does |
|---|---|---|---|---|---|
| `/static/*` | GET | no | no | no | **Never reached** — edge serves from disk |
| `/public/baseline` | GET | no | no | no | `a + b` query-sum |
| `/public/json/{count}` | GET | no | no | no | Slice dataset, serialize JSON |
| `/api/items/{id}` | GET | JWT | L1 → L2 → DB | SELECT on miss | Cache-aside read |
| `/api/items/{id}` | POST | JWT | invalidate L1+L2 | UPDATE | Parse body, write DB, invalidate cache |
| `/api/me` | GET | JWT | L1 → L2 → DB | SELECT on miss | Read user by X-User-Id |

## Workload

Two h2load instances run in parallel against the same compose stack:

**Reads** (20,000 URIs in `production-stack-reads.txt`, round-robin):

| Category | Count | Share | Handled by |
|---|---|---|---|
| `/static/*` | 6,000 | 30% | edge (disk, gzip_static) |
| `/public/baseline` | 2,000 | 10% | server (no auth, no cache) |
| `/api/items/{id}` (IDs 1–10,000) | 10,000 | 50% | edge → authsvc → server (cache-aside) |
| `/api/me` | 2,000 | 10% | edge → authsvc → server (cache-aside) |

**Writes** (20 URIs in `production-stack-writes.txt`, round-robin, with JSON body):

| Category | URIs | What |
|---|---|---|
| `POST /api/items/{id}` (IDs 1–20) | 20 | UPDATE + cache invalidate |

The reads instance uses `-c $conns -m 16`. The writes instance uses `-c $(conns/8) -m 8`. Both carry `Authorization: Bearer <jwt>` so all `/api/*` requests authenticate successfully.

IDs 1–20 are targeted by both reads and writes, creating realistic cache churn on those entries. IDs 21–10,000 are read-only with stable cache behavior.

## Docker Compose

Every production-stack entry ships `compose.production-stack.yml` with exactly four services:

| Service | Role | Image |
|---|---|---|
| `edge` | Reverse proxy, TLS, static files, auth_request | nginx (or equivalent) |
| `cache` | Redis for L2 cache (framework's HybridCache backend) | `redis:7-alpine` with seed entrypoint |
| `authsvc` | JWT HMAC-SHA256 verifier (shared, unmodified) | Built from `frameworks/_shared/authsvc/` |
| `server` | The framework — CRUD handlers with HybridCache | Built from the framework's Dockerfile |

### Required compose settings

Same as [Gateway-64](../h2-gateway/gateway-64/implementation/#required-compose-settings): `network_mode: host`, pinned `cpuset`, `seccomp:unconfined`, and memlock/nofile ulimits on all four services.

### Environment variables

| Variable | Set on | Value |
|---|---|---|
| `JWT_SECRET` | authsvc | `httparena-bench-secret-do-not-use-in-production` |
| `AUTHSVC_LISTEN` | authsvc | `0.0.0.0:9090` |
| `DATABASE_URL` | server | Postgres connection string (set by benchmark script) |
| `REDIS_URL` | server | `redis://127.0.0.1:6379` |
| `CERTS_DIR` | edge | TLS certificate directory (set by benchmark script) |
| `DATA_DIR` | edge, cache | Dataset + static files + seed data |

## CPU allocation

64 logical CPUs (32 physical + 32 SMT siblings) split across four services. The split is the entry's choice, but the reference entry's empirically-tuned split is:

| Service | Physical | Logical | Rationale |
|---|---|---|---|
| edge | 15 | 30 | TLS termination + h2 framing + auth_request subrequests |
| cache | 1 | 2 | Redis is single-threaded; more cores don't help |
| authsvc | 4 | 8 | HMAC-SHA256 is CPU-bound and parallelizable. 4 cores is empirically optimal on the reference hardware — going to 5 causes a cliff (likely CCX/L3 boundary). |
| server | 12 | 24 | Framework CRUD handlers + HybridCache + Postgres client |

**Important tuning finding:** authsvc scales linearly with cores (HMAC-SHA256 is embarrassingly parallel) BUT stealing cores from server or edge to give to authsvc often makes overall throughput worse because the downstream services can't keep up. The optimal split is where edge, authsvc, and server are all near their utilization ceiling simultaneously.

## Database

Two tables, both seeded by `data/pgdb-seed.sql`:

**`items`** — 100,000 rows, used by `/api/items/{id}`:
```sql
CREATE TABLE items (
    id INTEGER PRIMARY KEY,
    name TEXT, category TEXT, price INTEGER, quantity INTEGER,
    active BOOLEAN, tags JSONB, rating_score INTEGER, rating_count INTEGER
);
```

**`users`** — 4 rows, used by `/api/me`:
```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT, email TEXT, plan TEXT
);
```

## What this test measures

- **Full production stack throughput** with real JWT auth, real cache hierarchy, real DB writes
- **Framework cache abstraction efficiency** — HybridCache, Rails.cache, Django cache, etc. under L1/L2 pressure with 10K-item working set
- **JWT verification cost** — every `/api/*` request does real HMAC-SHA256 crypto at the edge
- **Cache-aside correctness** — reads populate cache on miss, writes invalidate, TTL cycles naturally
- **CRUD write path** — JSON body parsing, Postgres UPDATE, cache invalidation
- **CPU allocation strategy** — how entries balance edge/auth/server on a fixed 64-CPU budget

## Parameters

| Parameter | Value |
|---|---|
| Endpoints | `/static/*`, `/public/baseline`, `/public/json/{count}`, `/api/items/{id}` (GET+POST), `/api/me` |
| Connections | 256, 1,024 |
| Streams per connection | 16 (`-m 16`) for reads, 8 for writes |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | Two parallel h2load instances (reads + writes) |
| Auth | JWT HMAC-SHA256 verified on every `/api/*` request (no caching) |
| Cache | L1 in-process + L2 Redis, ≤1s TTL for items, ≤30s for users |
| Item working set | 10,000 unique IDs (IDs 1–10,000) |
| Write targets | 20 IDs (1–20), overlapping with reads |
| Total CPU budget | 64 logical, split across 4 services |
| Port | 8443 (HTTPS/h2) |
| Orchestration | Docker Compose (`compose.production-stack.yml`) |
