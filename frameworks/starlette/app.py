import json
import os
from contextlib import asynccontextmanager

import asyncpg
import redis.asyncio as aioredis
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.gzip import GZipMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, Response
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles


# -- Dataset -----------------------------------------------------------------

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET_ITEMS = []
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET_ITEMS = json.load(dataset_file)
except Exception:
    # A missing or broken dataset serves an empty list, it never stops the boot
    pass


# -- Routes ------------------------------------------------------------------

async def pipeline(request: Request):
    return PlainTextResponse(b"ok")


async def baseline11(request: Request):
    total = 0
    for value in request.query_params.values():
        try:
            total += int(value)
        except ValueError:
            pass
    if request.method == "POST":
        body = await request.body()
        if body:
            try:
                total += int(body.strip())
            except ValueError:
                pass
    return PlainTextResponse(str(total))


async def json_items(request: Request):
    count = request.path_params["count"]
    if count < 0:
        count = 0
    if count > len(DATASET_ITEMS):
        count = len(DATASET_ITEMS)
    try:
        m = int(request.query_params.get("m", 1))
    except ValueError:
        m = 1
    items = []
    for dsitem in DATASET_ITEMS[:count]:
        item = dict(dsitem)
        item["total"] = dsitem["price"] * dsitem["quantity"] * m
        items.append(item)
    return JSONResponse({"items": items, "count": count})


async def upload(request: Request):
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
    return PlainTextResponse(str(size))



# -- Postgres and Redis ------------------------------------------------------
# Wired only for the profiles that use them, so both stay None otherwise and the
# handlers answer without touching them. uvicorn forks one worker per core and
# each gets its own pool, so the harness's budget is split across them rather
# than opened by each.

PG_POOL = None
REDIS = None

ITEM_COLUMNS = (
    "id, name, category, price, quantity, active, tags, rating_score, rating_count"
)

# The crud profile reads and writes the same ids, so a long TTL would answer from
# a copy the writes have already moved past.
CRUD_TTL_MS = 200


def _worker_count():
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except Exception:
        return 1


async def _startup():
    global PG_POOL, REDIS
    dsn = os.environ.get("DATABASE_URL")
    if dsn:
        budget = int(os.environ.get("DATABASE_MAX_CONN", "256"))
        # headroom for superuser_reserved_connections, split across the workers
        per = max(1, (budget - 8) // _worker_count())
        try:
            PG_POOL = await asyncpg.create_pool(dsn, min_size=1, max_size=per)
        except Exception:
            PG_POOL = None
    url = os.environ.get("REDIS_URL")
    if url:
        try:
            REDIS = aioredis.from_url(url, decode_responses=True)
        except Exception:
            REDIS = None


def _item(row):
    tags = row["tags"]
    return {
        "id": row["id"],
        "name": row["name"],
        "category": row["category"],
        "price": row["price"],
        "quantity": row["quantity"],
        "active": row["active"],
        # tags is a JSONB column, so it arrives as text unless a codec is set
        "tags": json.loads(tags) if isinstance(tags, str) else tags,
        "rating": {"score": row["rating_score"], "count": row["rating_count"]},
    }


def _int(request, name, fallback):
    try:
        return int(request.query_params.get(name, fallback))
    except (TypeError, ValueError):
        return fallback


async def async_db(request: Request):
    if PG_POOL is None:
        return JSONResponse({"items": [], "count": 0})
    limit = max(1, min(50, _int(request, "limit", 50)))
    try:
        rows = await PG_POOL.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
            _int(request, "min", 10), _int(request, "max", 50), limit,
        )
    except Exception:
        return JSONResponse({"items": [], "count": 0})
    items = [_item(r) for r in rows]
    return JSONResponse({"items": items, "count": len(items)})


async def crud_list(request: Request):
    if PG_POOL is None:
        return JSONResponse({"error": "DB not available"}, status_code=500)
    category = request.query_params.get("category") or "electronics"
    page = max(1, _int(request, "page", 1))
    limit = max(1, min(50, _int(request, "limit", 10)))
    try:
        rows = await PG_POOL.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE category = $1 ORDER BY id "
            "LIMIT $2 OFFSET $3",
            category, limit, (page - 1) * limit,
        )
    except Exception:
        return JSONResponse({"error": "query failed"}, status_code=500)
    items = [_item(r) for r in rows]
    return JSONResponse(
        {"items": items, "total": len(items), "page": page, "limit": limit}
    )


async def crud_create(request: Request):
    if PG_POOL is None:
        return JSONResponse({"error": "DB not available"}, status_code=500)
    try:
        body = json.loads(await request.body())
    except Exception:
        return JSONResponse({"error": "insert failed"}, status_code=500)
    try:
        row = await PG_POOL.fetchrow(
            "INSERT INTO items (id, name, category, price, quantity, active, tags, "
            "rating_score, rating_count) "
            "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) "
            "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 "
            "RETURNING id",
            body.get("id"), body.get("name", "New Product"),
            body.get("category", "test"), body.get("price", 0),
            body.get("quantity", 0),
        )
    except Exception:
        return JSONResponse({"error": "insert failed"}, status_code=500)
    return JSONResponse(
        {
            "id": row["id"], "name": body.get("name"),
            "category": body.get("category"), "price": body.get("price"),
            "quantity": body.get("quantity"),
        },
        status_code=201,
    )


# Cache-aside on Redis where the harness provides it - crud is the one profile
# that does, and the cache is shared across the workers as a per-worker dict
# would not be.
async def crud_read(request: Request):
    if PG_POOL is None:
        return JSONResponse({"error": "DB not available"}, status_code=500)
    item_id = request.path_params["item_id"]
    key = f"crud:{item_id}"
    if REDIS is not None:
        try:
            hit = await REDIS.get(key)
        except Exception:
            hit = None
        if hit:
            return Response(
                hit, media_type="application/json", headers={"X-Cache": "HIT"}
            )
    try:
        row = await PG_POOL.fetchrow(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1", item_id
        )
    except Exception:
        return JSONResponse({"error": "query failed"}, status_code=500)
    if row is None:
        return Response(status_code=404)
    body = json.dumps(_item(row))
    if REDIS is not None:
        try:
            await REDIS.set(key, body, px=CRUD_TTL_MS)
        except Exception:
            pass
    return Response(body, media_type="application/json", headers={"X-Cache": "MISS"})


async def crud_update(request: Request):
    if PG_POOL is None:
        return JSONResponse({"error": "DB not available"}, status_code=500)
    item_id = request.path_params["item_id"]
    try:
        body = json.loads(await request.body())
    except Exception:
        return JSONResponse({"error": "update failed"}, status_code=500)
    try:
        tag = await PG_POOL.execute(
            "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
            body.get("name", "Updated"), body.get("price", 0),
            body.get("quantity", 0), item_id,
        )
    except Exception:
        return JSONResponse({"error": "update failed"}, status_code=500)
    if tag.endswith(" 0"):
        return Response(status_code=404)
    if REDIS is not None:
        try:
            await REDIS.delete(f"crud:{item_id}")
        except Exception:
            pass
    return JSONResponse(
        {
            "id": item_id, "name": body.get("name"), "price": body.get("price"),
            "quantity": body.get("quantity"),
        }
    )


routes = [
    Route("/pipeline", pipeline, methods=["GET"]),
    Route("/baseline11", baseline11, methods=["GET", "POST"]),
    Route("/baseline2", baseline11, methods=["GET"]),
    Route("/json/{count:int}", json_items, methods=["GET"]),
    Route("/upload", upload, methods=["POST"]),
    Route("/async-db", async_db, methods=["GET"]),
    Route("/crud/items", crud_list, methods=["GET"]),
    Route("/crud/items", crud_create, methods=["POST"]),
    Route("/crud/items/{item_id:int}", crud_read, methods=["GET"]),
    Route("/crud/items/{item_id:int}", crud_update, methods=["PUT"]),
    # StaticFiles streams the body off disk on every request, which the static
    # profiles require in every mode.
    Mount("/static", app=StaticFiles(directory="/data/static"), name="static"),
]

# standard mode: gzip is Starlette's own GZipMiddleware, with the settings the
# fastapi entry gives it, so json-comp measures the same middleware on both
middleware = [Middleware(GZipMiddleware, minimum_size=1000, compresslevel=5)]

# Starlette 1.x takes a lifespan rather than on_startup
@asynccontextmanager
async def _lifespan(_app):
    await _startup()
    yield


app = Starlette(routes=routes, middleware=middleware, lifespan=_lifespan)
