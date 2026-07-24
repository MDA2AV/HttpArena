import os
import sys
import multiprocessing
import json
from contextlib import asynccontextmanager

import asyncpg

from fastapi import FastAPI, Request, Response, Path, Query, HTTPException
from fastapi.responses import PlainTextResponse, JSONResponse
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.applications import BaseHTTPMiddleware
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
    global PG_POOL, NoResetConnection
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
    yield
    if PG_POOL:
        await PG_POOL.close()
    PG_POOL = None


# -- APP ---------------------------------------------------------------------

app = FastAPI(lifespan=lifespan)

app.add_middleware(GZipMiddleware, minimum_size=1, compresslevel=5)

class ServerHeaderMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        response = await call_next(request)
        response.headers["Server"] = "FastAPI"
        return response 

app.add_middleware(ServerHeaderMiddleware)


# -- Routes ------------------------------------------------------------------

@app.get("/pipeline")
async def pipeline():
    return PlainTextResponse(b"ok")


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


app.mount("/static", StaticFiles(directory="/data/static/"), name="static")

