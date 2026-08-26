import asyncio
import os
import sys
import multiprocessing
import json
from contextlib import asynccontextmanager

import asyncpg
import redis.asyncio as aioredis

from fastapi import FastAPI, Request, Response, Path, Query, HTTPException
from fastapi.responses import PlainTextResponse, JSONResponse
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.staticfiles import StaticFiles


# -- Dataset and constants --------------------------------------------------------

CPU_COUNT = int(multiprocessing.cpu_count())
WRK_COUNT = min(len(os.sched_getaffinity(0)), 128)
WRK_COUNT = max(WRK_COUNT, 4)

DATASET_LARGE_PATH = "/data/dataset-large.json"
DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET_ITEMS = None
try:
    with open(DATASET_PATH) as file:
        DATASET_ITEMS = json.load(file)
except Exception:
    pass


# -- Postgres DB ------------------------------------------------------------

PG_POOL: asyncpg.Pool | None = None
REDIS = None

CRUD_COLUMNS = (
    "id, name, category, price, quantity, active, tags, rating_score, rating_count"
)

# The crud profile reads and writes the same ids, so a long TTL would answer from
# a copy the writes have already moved past.
CRUD_TTL_MS = 200

PG_QUERY = (
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count "
    "FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3"
)

class NoResetConnection(asyncpg.Connection):
    __slots__ = ()
    def get_reset_query(self):
        return ""

@asynccontextmanager
async def lifespan(application: FastAPI):
    global PG_POOL, REDIS, NoResetConnection
    DATABASE_URL = os.environ.get("DATABASE_URL")
    if DATABASE_URL:
        try:
            if DATABASE_URL.startswith("postgres://"):
                DATABASE_URL = "postgresql://" + DATABASE_URL[len("postgres://"):]
            PG_POOL_MAX_SIZE = 2
            DATABASE_MAX_CONN = os.environ.get("DATABASE_MAX_CONN", None)
            if DATABASE_MAX_CONN:
                pool_size = int(DATABASE_MAX_CONN) * 0.92 / WRK_COUNT
                PG_POOL_MAX_SIZE = int(pool_size + 0.95)
            PG_POOL = await asyncpg.create_pool(
                dsn = DATABASE_URL,
                min_size = 1,
                max_size = max(PG_POOL_MAX_SIZE, 2),
                connection_class = NoResetConnection
            )
        except Exception:
            PG_POOL = None
    REDIS_URL = os.environ.get("REDIS_URL")
    if REDIS_URL:
        try:
            REDIS = aioredis.from_url(REDIS_URL, decode_responses=True)
        except Exception:
            REDIS = None
    yield
    if PG_POOL:
        await PG_POOL.close()
    PG_POOL = None


# -- APP ---------------------------------------------------------------------

app = FastAPI(lifespan=lifespan)

app.add_middleware(GZipMiddleware, minimum_size=1000, compresslevel=5)


# -- Routes ------------------------------------------------------------------

@app.get("/pipeline")
async def pipeline():
    return PlainTextResponse(b"ok")


@app.get("/delay/{ms}")
async def delay_endpoint(ms: int = Path(...)):
    # asyncio.sleep suspends this coroutine and returns control to the loop, so
    # the wait costs one timer entry rather than one worker. `ms` is a local,
    # which is what keeps 32K overlapping requests from reading each other's.
    if ms > 0:
        await asyncio.sleep(ms / 1000)
    return PlainTextResponse(str(ms))


@app.api_route("/baseline11", methods=["GET", "POST"])
async def baseline11(request: Request):
    total = 0
    for val in request.query_params.values():
        try:
            total += int(val)
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


@app.get("/json/{count}")
@app.get("/json-comp/{count}")
async def json_endpoint(request: Request, count: int = Path(...), m: float = Query(...)):
    global DATASET_ITEMS
    if not DATASET_ITEMS:
        return PlainTextResponse("No dataset", 500)
    try:
        items = [ ]
        for idx, dsitem in enumerate(DATASET_ITEMS):
            if idx >= count:
                break
            item = dict(dsitem)
            item["total"] = dsitem["price"] * dsitem["quantity"] * m
            items.append(item)
        return JSONResponse( { "items": items, "count": len(items) } )
    except Exception:
        return JSONResponse( { "items": [ ], "count": 0 } )


@app.get("/async-db")
async def async_db_endpoint(request: Request, min_val: float = Query(..., alias="min"), max_val: float = Query(..., alias="max"), limit: int = Query(...)):
    global PG_POOL
    if not PG_POOL:
        return JSONResponse( { "items": [ ], "count": 0 } )
    try:
        db_conn = await PG_POOL.acquire()
        try:
            rows = await db_conn.fetch(PG_QUERY, min_val, max_val, limit)
        finally:
            await PG_POOL.release(db_conn)
        items = [
            {
                'id'      : row['id'],
                'name'    : row['name'],
                'category': row['category'],
                'price'   : row['price'],
                'quantity': row['quantity'],
                'active'  : row['active'],
                'tags'    : json.loads(row['tags']) if isinstance(row['tags'], str) else row['tags'],
                'rating': {
                    'score': row['rating_score'],
                    'count': row['rating_count'],
                }
            }
            for row in rows
        ]
        return JSONResponse( { "items": items, "count": len(items) } )
    except Exception:
        return JSONResponse( { "items": [ ], "count": 0 } )


@app.post("/upload")
async def upload_endpoint(request: Request):
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
    return PlainTextResponse(str(size))



# -- crud --------------------------------------------------------------------

def _crud_item(row):
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


@app.get("/crud/items")
async def crud_list(category: str = "electronics", page: int = 1, limit: int = 10):
    if not PG_POOL:
        return JSONResponse({"error": "DB not available"}, status_code=500)
    page = max(1, page)
    limit = max(1, min(50, limit))
    try:
        rows = await PG_POOL.fetch(
            f"SELECT {CRUD_COLUMNS} FROM items WHERE category = $1 ORDER BY id "
            "LIMIT $2 OFFSET $3",
            category, limit, (page - 1) * limit,
        )
    except Exception:
        return JSONResponse({"error": "query failed"}, status_code=500)
    items = [_crud_item(r) for r in rows]
    return JSONResponse(
        {"items": items, "total": len(items), "page": page, "limit": limit}
    )


@app.post("/crud/items")
async def crud_create(request: Request):
    if not PG_POOL:
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
@app.get("/crud/items/{item_id}")
async def crud_read(item_id: int):
    if not PG_POOL:
        return JSONResponse({"error": "DB not available"}, status_code=500)
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
            f"SELECT {CRUD_COLUMNS} FROM items WHERE id = $1 LIMIT 1", item_id
        )
    except Exception:
        return JSONResponse({"error": "query failed"}, status_code=500)
    if row is None:
        return Response(status_code=404)
    body = json.dumps(_crud_item(row))
    if REDIS is not None:
        try:
            await REDIS.set(key, body, px=CRUD_TTL_MS)
        except Exception:
            pass
    return Response(body, media_type="application/json", headers={"X-Cache": "MISS"})


@app.put("/crud/items/{item_id}")
async def crud_update(item_id: int, request: Request):
    if not PG_POOL:
        return JSONResponse({"error": "DB not available"}, status_code=500)
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


app.mount("/static", StaticFiles(directory="/data/static/"), name="static")

