import gzip
import json
import multiprocessing
import os

import asyncpg
import redis.asyncio as aioredis
from sanic import Sanic
from sanic.response import ResponseStream
from sanic.response import json as json_response
from sanic.response import raw, text

# Sanic ships no compression middleware, so json-comp is gzipped by hand in the
# response middleware below. 1 KB threshold and level 6 are what koa-compress
# and @fastify/compress use by default, so the entry stays comparable.
MIN_COMPRESS_SIZE = 1024
GZIP_LEVEL = 6

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET_ITEMS = json.load(dataset_file)
except Exception:
    DATASET_ITEMS = []


def cpu_count():
    # cgroup quota first, like koa's getCPUCount: the benchmark caps the
    # container, and the host core count would fork far too many workers.
    try:
        with open("/sys/fs/cgroup/cpu.max") as quota_file:
            quota, period = quota_file.read().split()
        if quota != "max":
            limit = int(quota) // int(period)
            if limit >= 1:
                return limit
    except Exception:
        pass
    try:
        return len(os.sched_getaffinity(0))
    except Exception:
        return multiprocessing.cpu_count() or 1


app = Sanic("httparena")
app.config.ACCESS_LOG = False


@app.get("/pipeline")
async def pipeline(request):
    return text("ok")


@app.route("/baseline11", methods=["GET", "POST"])
async def baseline11(request):
    total = 0
    for values in request.args.values():
        for value in values:
            try:
                total += int(value)
            except (TypeError, ValueError):
                pass
    if request.method == "POST" and request.body:
        try:
            total += int(request.body.strip())
        except (TypeError, ValueError):
            pass
    return text(str(total))


@app.get("/json/<count:int>")
async def json_items(request, count):
    if count < 0:
        count = 0
    elif count > len(DATASET_ITEMS):
        count = len(DATASET_ITEMS)
    try:
        m = int(request.args.get("m", 1))
    except (TypeError, ValueError):
        m = 1
    items = [
        {**item, "total": item["price"] * item["quantity"] * m}
        for item in DATASET_ITEMS[:count]
    ]
    return json_response({"items": items, "count": count})


@app.post("/upload", stream=True)
async def upload(request):
    size = 0
    while True:
        chunk = await request.stream.read()
        if chunk is None:
            break
        size += len(chunk)
    return text(str(size))



# -- Postgres and Redis ------------------------------------------------------
# Wired only for the profiles that use them, so both stay None otherwise and the
# handlers answer without touching them. Sanic starts one worker process per
# core and each gets its own pool, so the harness's budget is split across them
# rather than opened by each.

PG_POOL = None
REDIS = None

ITEM_COLUMNS = (
    "id, name, category, price, quantity, active, tags, rating_score, rating_count"
)

# The crud profile reads and writes the same ids, so a long TTL would answer from
# a copy the writes have already moved past.
CRUD_TTL_MS = 200

STATIC_ROOT = "/data/static"
MIME_TYPES = {
    ".css": "text/css", ".js": "application/javascript", ".html": "text/html",
    ".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp",
    ".json": "application/json",
}


def _worker_count():
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except Exception:
        return 1


@app.before_server_start
async def _open_pools(application, _loop):
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


def _int(request, name, fallback):
    try:
        return int(request.args.get(name, fallback))
    except (TypeError, ValueError):
        return fallback


@app.get("/baseline2")
async def baseline2(request):
    return await baseline11(request)


@app.get("/async-db")
async def async_db(request):
    if PG_POOL is None:
        return json_response({"items": [], "count": 0})
    limit = max(1, min(50, _int(request, "limit", 50)))
    try:
        rows = await PG_POOL.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
            _int(request, "min", 10), _int(request, "max", 50), limit,
        )
    except Exception:
        return json_response({"items": [], "count": 0})
    items = [_item(r) for r in rows]
    return json_response({"items": items, "count": len(items)})


@app.route("/crud/items", methods=["GET", "POST"])
async def crud_collection(request):
    if PG_POOL is None:
        return json_response({"error": "DB not available"}, status=500)
    if request.method == "POST":
        try:
            body = json.loads(request.body)
        except Exception:
            return json_response({"error": "insert failed"}, status=500)
        try:
            row = await PG_POOL.fetchrow(
                "INSERT INTO items (id, name, category, price, quantity, active, "
                "tags, rating_score, rating_count) "
                "VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0) "
                "ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, "
                "quantity = $5 RETURNING id",
                body.get("id"), body.get("name", "New Product"),
                body.get("category", "test"), body.get("price", 0),
                body.get("quantity", 0),
            )
        except Exception:
            return json_response({"error": "insert failed"}, status=500)
        return json_response(
            {
                "id": row["id"], "name": body.get("name"),
                "category": body.get("category"), "price": body.get("price"),
                "quantity": body.get("quantity"),
            },
            status=201,
        )
    category = request.args.get("category") or "electronics"
    page = max(1, _int(request, "page", 1))
    limit = max(1, min(50, _int(request, "limit", 10)))
    try:
        rows = await PG_POOL.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE category = $1 ORDER BY id "
            "LIMIT $2 OFFSET $3",
            category, limit, (page - 1) * limit,
        )
    except Exception:
        return json_response({"error": "query failed"}, status=500)
    items = [_item(r) for r in rows]
    return json_response(
        {"items": items, "total": len(items), "page": page, "limit": limit}
    )


# Cache-aside on Redis where the harness provides it - crud is the one profile
# that does, and the cache is shared across the workers as a per-worker dict
# would not be.
@app.route("/crud/items/<item_id:int>", methods=["GET", "PUT"])
async def crud_item(request, item_id):
    if PG_POOL is None:
        return json_response({"error": "DB not available"}, status=500)
    key = f"crud:{item_id}"
    if request.method == "PUT":
        try:
            body = json.loads(request.body)
        except Exception:
            return json_response({"error": "update failed"}, status=500)
        try:
            tag = await PG_POOL.execute(
                "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
                body.get("name", "Updated"), body.get("price", 0),
                body.get("quantity", 0), item_id,
            )
        except Exception:
            return json_response({"error": "update failed"}, status=500)
        if tag.endswith(" 0"):
            return raw(b"", status=404)
        if REDIS is not None:
            try:
                await REDIS.delete(key)
            except Exception:
                pass
        return json_response(
            {
                "id": item_id, "name": body.get("name"),
                "price": body.get("price"), "quantity": body.get("quantity"),
            }
        )
    if REDIS is not None:
        try:
            hit = await REDIS.get(key)
        except Exception:
            hit = None
        if hit:
            return raw(
                hit.encode(), content_type="application/json",
                headers={"X-Cache": "HIT"},
            )
    try:
        row = await PG_POOL.fetchrow(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1", item_id
        )
    except Exception:
        return json_response({"error": "query failed"}, status=500)
    if row is None:
        return raw(b"", status=404)
    body = json.dumps(_item(row))
    if REDIS is not None:
        try:
            await REDIS.set(key, body, px=CRUD_TTL_MS)
        except Exception:
            pass
    return raw(
        body.encode(), content_type="application/json", headers={"X-Cache": "MISS"}
    )


# Static bodies are read from disk on every request, which the static profiles
# require in every mode. file_stream hands back the handle rather than holding
# the bytes, and the encoding is left to the response middleware below.
@app.get("/static/<filename:str>")
async def static_file(request, filename):
    if "/" in filename or ".." in filename:
        return raw(b"", status=404)
    path = os.path.join(STATIC_ROOT, filename)
    if not os.path.isfile(path):
        return raw(b"", status=404)
    ext = os.path.splitext(filename)[1]
    # Read the body rather than streaming it. file_stream returns a
    # ResponseStream, which the response middleware below cannot read - it
    # raised on every single static request, and the traceback it logged each
    # time ran the container log to 240MB over one profile.
    with open(path, "rb") as fh:
        body = fh.read()
    return raw(body, content_type=MIME_TYPES.get(ext, "application/octet-stream"))


@app.on_response
async def compress_response(request, response):
    # Nothing is compressed unless the client negotiated it, so the plain
    # /json profile keeps sending plain JSON on the same route.
    #
    # A streaming response has no body to read and raises here; the error is
    # caught by Sanic and logged, so it costs a traceback per request rather
    # than a failure. Skip those instead.
    if isinstance(response, ResponseStream):
        return
    body = response.body
    if not body or len(body) < MIN_COMPRESS_SIZE:
        return
    if "gzip" not in request.headers.get("accept-encoding", ""):
        return
    if response.headers.get("content-encoding"):
        return
    response.body = gzip.compress(body, GZIP_LEVEL)
    response.headers["content-encoding"] = "gzip"
    response.headers["content-length"] = str(len(response.body))
    response.headers["vary"] = "Accept-Encoding"


if __name__ == "__main__":
    # Sanic's own worker manager, not gunicorn: the main process opens the
    # listening socket and hands it to one worker process per core.
    # json-tls and static-tls are unsubscribed: sanic 25.3.0 cannot serve TLS
    # under its worker manager. The listener binds and accepts, then never
    # sends a ServerHello -- at any worker count, and whether it is the only
    # listener or a second prepare() alongside 8080. A second *plaintext*
    # prepare() on another port answers fine, so it is TLS specifically.
    # single_process=True does serve it, which would pin the entry to one core
    # and publish a number that is not comparable to anything else here.
    # (A prebuilt ssl.SSLContext is not an option either: the manager spawns,
    # and an SSLContext cannot be pickled.)
    app.run(
        host="0.0.0.0",
        port=8080,
        workers=cpu_count(),
        access_log=False,
        motd=False,
    )
