import json
import os

import asyncpg
import redis.asyncio as aioredis
from litestar import HttpMethod, Litestar, MediaType, Request, Response, get, post, put, route
from litestar.config.compression import CompressionConfig
from litestar.static_files import create_static_files_router

MAX_BODY = 30 * 1024 * 1024

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET_ITEMS = []
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET_ITEMS = json.load(dataset_file)
except Exception:
    pass


@get("/pipeline", media_type=MediaType.TEXT, sync_to_thread=False)
def pipeline() -> str:
    return "ok"


@route(
    "/baseline11",
    http_method=[HttpMethod.GET, HttpMethod.POST],
    media_type=MediaType.TEXT,
    status_code=200,
)
async def baseline11(request: Request) -> str:
    total = 0
    for value in request.query_params.values():
        try:
            total += int(value)
        except (TypeError, ValueError):
            pass
    if request.method == "POST":
        body = await request.body()
        try:
            total += int(body.strip())
        except (TypeError, ValueError):
            pass
    return str(total)


@get("/json/{count:int}", sync_to_thread=False)
def json_items(count: int, m: int = 1) -> dict:
    items = []
    for item in DATASET_ITEMS[:count]:
        processed = dict(item)
        processed["total"] = item["price"] * item["quantity"] * m
        items.append(processed)
    return {"items": items, "count": len(items)}


@post("/upload", media_type=MediaType.TEXT, status_code=200)
async def upload(request: Request) -> str:
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
    return str(size)



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


async def _startup(_app) -> None:
    global PG_POOL, REDIS
    dsn = os.environ.get("DATABASE_URL")
    if dsn and PG_POOL is None:
        budget = int(os.environ.get("DATABASE_MAX_CONN", "256"))
        # headroom for superuser_reserved_connections, split across the workers
        per = max(1, (budget - 8) // _worker_count())
        try:
            PG_POOL = await asyncpg.create_pool(dsn, min_size=1, max_size=per)
        except Exception:
            PG_POOL = None
    url = os.environ.get("REDIS_URL")
    if url and REDIS is None:
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


@get("/async-db")
async def async_db(min: int = 10, max: int = 50, limit: int = 50) -> dict:
    if PG_POOL is None:
        return {"items": [], "count": 0}
    limit = 1 if limit < 1 else (50 if limit > 50 else limit)
    try:
        rows = await PG_POOL.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
            min, max, limit,
        )
    except Exception:
        return {"items": [], "count": 0}
    items = [_item(r) for r in rows]
    return {"items": items, "count": len(items)}


@get("/crud/items")
async def crud_list(category: str = "electronics", page: int = 1, limit: int = 10) -> Response:
    if PG_POOL is None:
        return Response({"error": "DB not available"}, status_code=500)
    page = 1 if page < 1 else page
    limit = 1 if limit < 1 else (50 if limit > 50 else limit)
    try:
        rows = await PG_POOL.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE category = $1 ORDER BY id "
            "LIMIT $2 OFFSET $3",
            category, limit, (page - 1) * limit,
        )
    except Exception:
        return Response({"error": "query failed"}, status_code=500)
    items = [_item(r) for r in rows]
    return Response({"items": items, "total": len(items), "page": page, "limit": limit})


@post("/crud/items", status_code=201)
async def crud_create(request: Request) -> Response:
    if PG_POOL is None:
        return Response({"error": "DB not available"}, status_code=500)
    try:
        body = json.loads(await request.body())
    except Exception:
        return Response({"error": "insert failed"}, status_code=500)
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
        return Response({"error": "insert failed"}, status_code=500)
    return Response(
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
@get("/crud/items/{item_id:int}")
async def crud_read(item_id: int) -> Response:
    if PG_POOL is None:
        return Response({"error": "DB not available"}, status_code=500)
    key = f"crud:{item_id}"
    if REDIS is not None:
        try:
            hit = await REDIS.get(key)
        except Exception:
            hit = None
        if hit:
            return Response(
                hit.encode(), media_type="application/json",
                headers={"X-Cache": "HIT"},
            )
    try:
        row = await PG_POOL.fetchrow(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1", item_id
        )
    except Exception:
        return Response({"error": "query failed"}, status_code=500)
    if row is None:
        return Response(b"", status_code=404)
    body = json.dumps(_item(row))
    if REDIS is not None:
        try:
            await REDIS.set(key, body, px=CRUD_TTL_MS)
        except Exception:
            pass
    return Response(
        body.encode(), media_type="application/json", headers={"X-Cache": "MISS"}
    )


@put("/crud/items/{item_id:int}")
async def crud_update(item_id: int, request: Request) -> Response:
    if PG_POOL is None:
        return Response({"error": "DB not available"}, status_code=500)
    try:
        body = json.loads(await request.body())
    except Exception:
        return Response({"error": "update failed"}, status_code=500)
    try:
        tag = await PG_POOL.execute(
            "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
            body.get("name", "Updated"), body.get("price", 0),
            body.get("quantity", 0), item_id,
        )
    except Exception:
        return Response({"error": "update failed"}, status_code=500)
    if tag.endswith(" 0"):
        return Response(b"", status_code=404)
    if REDIS is not None:
        try:
            await REDIS.delete(key := f"crud:{item_id}")
        except Exception:
            pass
    return Response(
        {
            "id": item_id, "name": body.get("name"), "price": body.get("price"),
            "quantity": body.get("quantity"),
        }
    )


app = Litestar(
    route_handlers=[
        pipeline,
        baseline11,
        json_items,
        upload,
        async_db,
        crud_list,
        crud_create,
        crud_read,
        crud_update,
        # The static router streams bodies off disk on every request, which the
        # static profiles require in every mode.
        create_static_files_router(path="/static", directories=["/data/static"]),
    ],
    compression_config=CompressionConfig(backend="gzip"),
    request_max_body_size=MAX_BODY,
    openapi_config=None,
    on_startup=[_startup],
)
