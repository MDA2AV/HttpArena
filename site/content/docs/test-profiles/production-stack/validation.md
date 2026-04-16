---
title: Validation
weight: 2
---

`validate.sh` brings up the full production-stack compose (edge + cache + authsvc + server) with `up --build -d`, waits up to 60 seconds for the HTTPS port to respond, runs the checks below, and tears the stack down.

## Checks performed

### Protocol and static files
1. **HTTP/2 protocol negotiation** — `curl --http2 /static/reset.css` must report HTTP/2
2. **`/static/reset.css`** — Content-Type `text/css`
3. **`/static/app.js`** — non-zero response body

### Public endpoints (no auth)
4. **`/public/baseline?a=13&b=42`** — returns `55`
5. **`/public/baseline?a=<random>&b=<random>`** — correct sum (anti-cheat)
6. **`/public/json/25`** — 25 items with computed `total = price × quantity`

### Auth wall — JWT required
7. **`GET /api/items/1`** (no Authorization header) — **HTTP 401**
8. **`GET /api/items/1`** (Authorization: Bearer invalid.token.here) — **HTTP 401**
9. **`POST /api/items/1`** (no Authorization header) — **HTTP 401**
10. **`POST /api/items/1`** (Authorization: Bearer invalid.token.here) — **HTTP 401**

### Authenticated CRUD — valid JWT
11. **`GET /api/items/1`** with valid JWT — returns item with `id=1`
12. **Cache-aside cycle** — `GET /api/items/7` twice:
    - First call: `X-Cache: MISS` (L1+L2 cold → Postgres query → populate both layers)
    - Second call: `X-Cache: HIT` (served from L1 or L2)
13. **`POST /api/items/2`** with valid JWT + JSON body — returns `204 No Content` (Postgres UPDATE + cache invalidation)
14. **POST invalidation** — warm cache for item 3, POST to item 3, GET item 3 again:
    - GET after POST shows `X-Cache: MISS` (proves `RemoveAsync` cleared both L1 and L2)
15. **`GET /api/me`** with valid JWT — returns user JSON with `id=42` (authsvc extracts `sub:42` from the JWT, edge forwards `X-User-Id: 42`, server reads user from Postgres via HybridCache)

Total: **15 production-stack checks** plus the compose startup itself.

## What validation proves

- **JWT verification works end-to-end**: valid tokens authenticate, invalid/missing tokens get 401
- **Both GET and POST are behind the auth wall**: can't read or write without a valid JWT
- **Cache-aside populates on miss**: first read of a cold key hits Postgres and populates cache
- **Cache-aside serves from cache on hit**: second read returns cached data
- **POST invalidates cache**: write clears both L1 and L2, forcing next read to re-query Postgres
- **User lookup chain works**: JWT `sub` claim → authsvc → X-User-Id header → server → Postgres/cache → user JSON

## JWT token for validation

Validation uses the pre-generated token at `data/jwt-token.txt`, signed with the secret `httparena-bench-secret-do-not-use-in-production`. The token contains `{"sub":"42","name":"Alice Chen","exp":<far-future>}`. authsvc verifies the HMAC-SHA256 signature and returns `X-User-Id: 42`.
