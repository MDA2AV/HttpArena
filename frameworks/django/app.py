import json
import os

import asyncpg
import django
import redis.asyncio as aioredis
from django.conf import settings

settings.configure(
    DEBUG=False,
    ALLOWED_HOSTS=["*"],
    SECRET_KEY="httparena",
    ROOT_URLCONF=__name__,
    MIDDLEWARE=["django.middleware.gzip.GZipMiddleware"],
    LOGGING_CONFIG=None,
)
django.setup()

from django.core.asgi import get_asgi_application  # noqa: E402
from django.http import FileResponse, HttpResponse, JsonResponse  # noqa: E402
from django.urls import path  # noqa: E402

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET = []
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET = json.load(dataset_file)
except OSError:
    pass


async def pipeline(request):
    return HttpResponse("ok", content_type="text/plain")


async def baseline11(request):
    total = 0
    for value in request.GET.values():
        try:
            total += int(value)
        except ValueError:
            pass
    if request.method == "POST":
        try:
            total += int(request.body.strip())
        except ValueError:
            pass
    return HttpResponse(str(total), content_type="text/plain")


async def json_items(request, count):
    try:
        m = int(request.GET.get("m", 1))
    except ValueError:
        m = 1
    items = []
    for item in DATASET[:count]:
        processed = dict(item)
        processed["total"] = item["price"] * item["quantity"] * m
        items.append(processed)
    return JsonResponse({"items": items, "count": len(items)})


async def upload(request):
    size = 0
    while True:
        chunk = request.read(262144)
        if not chunk:
            break
        size += len(chunk)
    return HttpResponse(str(size), content_type="text/plain")



# -- Postgres and Redis ------------------------------------------------------
# Wired lazily on first use: Django's ASGI application has no startup hook that
# runs inside the worker's event loop. uvicorn forks one worker per core and each
# gets its own pool, so the harness's budget is split across them.

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


async def _pool():
    global PG_POOL
    if PG_POOL is None:
        dsn = os.environ.get("DATABASE_URL")
        if not dsn:
            return None
        budget = int(os.environ.get("DATABASE_MAX_CONN", "256"))
        # headroom for superuser_reserved_connections, split across the workers
        per = max(1, (budget - 8) // _worker_count())
        try:
            PG_POOL = await asyncpg.create_pool(dsn, min_size=1, max_size=per)
        except Exception:
            return None
    return PG_POOL


async def _redis():
    global REDIS
    if REDIS is None:
        url = os.environ.get("REDIS_URL")
        if not url:
            return None
        try:
            REDIS = aioredis.from_url(url, decode_responses=True)
        except Exception:
            return None
    return REDIS


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
        return int(request.GET.get(name, fallback))
    except (TypeError, ValueError):
        return fallback


async def async_db(request):
    pool = await _pool()
    if pool is None:
        return JsonResponse({"items": [], "count": 0})
    limit = max(1, min(50, _int(request, "limit", 50)))
    try:
        rows = await pool.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
            _int(request, "min", 10), _int(request, "max", 50), limit,
        )
    except Exception:
        return JsonResponse({"items": [], "count": 0})
    items = [_item(r) for r in rows]
    return JsonResponse({"items": items, "count": len(items)})


async def crud_items(request):
    pool = await _pool()
    if pool is None:
        return JsonResponse({"error": "DB not available"}, status=500)
    if request.method == "POST":
        try:
            body = json.loads(request.body)
        except Exception:
            return JsonResponse({"error": "insert failed"}, status=500)
        try:
            row = await pool.fetchrow(
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
            return JsonResponse({"error": "insert failed"}, status=500)
        return JsonResponse(
            {
                "id": row["id"], "name": body.get("name"),
                "category": body.get("category"), "price": body.get("price"),
                "quantity": body.get("quantity"),
            },
            status=201,
        )
    category = request.GET.get("category") or "electronics"
    page = max(1, _int(request, "page", 1))
    limit = max(1, min(50, _int(request, "limit", 10)))
    try:
        rows = await pool.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE category = $1 ORDER BY id "
            "LIMIT $2 OFFSET $3",
            category, limit, (page - 1) * limit,
        )
    except Exception:
        return JsonResponse({"error": "query failed"}, status=500)
    items = [_item(r) for r in rows]
    return JsonResponse(
        {"items": items, "total": len(items), "page": page, "limit": limit}
    )


# Cache-aside on Redis where the harness provides it - crud is the one profile
# that does, and the cache is shared across the workers as a per-worker dict
# would not be.
async def crud_item(request, item_id):
    pool = await _pool()
    if pool is None:
        return JsonResponse({"error": "DB not available"}, status=500)
    rds = await _redis()
    key = f"crud:{item_id}"
    if request.method == "PUT":
        try:
            body = json.loads(request.body)
        except Exception:
            return JsonResponse({"error": "update failed"}, status=500)
        try:
            tag = await pool.execute(
                "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
                body.get("name", "Updated"), body.get("price", 0),
                body.get("quantity", 0), item_id,
            )
        except Exception:
            return JsonResponse({"error": "update failed"}, status=500)
        if tag.endswith(" 0"):
            return HttpResponse(status=404)
        if rds is not None:
            try:
                await rds.delete(key)
            except Exception:
                pass
        return JsonResponse(
            {
                "id": item_id, "name": body.get("name"),
                "price": body.get("price"), "quantity": body.get("quantity"),
            }
        )
    if rds is not None:
        try:
            hit = await rds.get(key)
        except Exception:
            hit = None
        if hit:
            resp = HttpResponse(hit, content_type="application/json")
            resp["X-Cache"] = "HIT"
            return resp
    try:
        row = await pool.fetchrow(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1", item_id
        )
    except Exception:
        return JsonResponse({"error": "query failed"}, status=500)
    if row is None:
        return HttpResponse(status=404)
    body = json.dumps(_item(row))
    if rds is not None:
        try:
            await rds.set(key, body, px=CRUD_TTL_MS)
        except Exception:
            pass
    resp = HttpResponse(body, content_type="application/json")
    resp["X-Cache"] = "MISS"
    return resp


# Static bodies are read from disk on every request, which the static profiles
# require in every mode. FileResponse streams the handle rather than holding the
# bytes, and the encoding is left to the GZipMiddleware configured above.
async def static_file(request, filename):
    if "/" in filename or ".." in filename:
        return HttpResponse(status=404)
    path = os.path.join(STATIC_ROOT, filename)
    if not os.path.isfile(path):
        return HttpResponse(status=404)
    ext = os.path.splitext(filename)[1]
    return FileResponse(
        open(path, "rb"),
        content_type=MIME_TYPES.get(ext, "application/octet-stream"),
    )


urlpatterns = [
    path("pipeline", pipeline),
    path("baseline11", baseline11),
    path("baseline2", baseline11),
    path("json/<int:count>", json_items),
    path("upload", upload),
    path("async-db", async_db),
    path("crud/items", crud_items),
    path("crud/items/<int:item_id>", crud_item),
    path("static/<str:filename>", static_file),
]

application = get_asgi_application()
