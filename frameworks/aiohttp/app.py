import asyncio
import json
import os
import signal
import ssl

import asyncpg
import redis.asyncio as aioredis
import uvloop
from aiohttp import web

PORT = 8080
BACKLOG = 4096
MAX_BODY = 64 * 1024 * 1024

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET = []
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET = json.load(dataset_file)
except Exception:
    DATASET = []


def cpu_count():
    # cgroup quota first, so the worker count follows the container limit
    # and not the host. Falls back to the CPU affinity mask, which is what
    # --cpuset-cpus restricts.
    try:
        with open("/sys/fs/cgroup/cpu.max") as cpu_max:
            quota, period = cpu_max.read().split()
        if quota != "max":
            limit = int(quota) // int(period)
            if limit >= 1:
                return limit
    except Exception:
        pass
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        return os.cpu_count() or 1


async def pipeline(request):
    return web.Response(body=b"ok", content_type="text/plain")


async def baseline11(request):
    total = 0
    for value in request.query.values():
        try:
            total += int(value)
        except ValueError:
            pass
    if request.method == "POST":
        try:
            total += int((await request.text()).strip())
        except ValueError:
            pass
    return web.Response(body=str(total).encode(), content_type="text/plain")


async def json_items(request):
    try:
        count = int(request.match_info["count"])
    except ValueError:
        count = 0
    if count < 0:
        count = 0
    elif count > len(DATASET):
        count = len(DATASET)
    try:
        m = int(request.query.get("m", 1))
    except ValueError:
        m = 1
    items = []
    for item in DATASET[:count]:
        processed = dict(item)
        processed["total"] = item["price"] * item["quantity"] * m
        items.append(processed)
    response = web.json_response({"items": items, "count": count})
    # standard mode: gzip comes from aiohttp's own response compression, which
    # picks the coding from Accept-Encoding and stays off when the header is absent
    response.enable_compression()
    return response


async def upload(request):
    size = 0
    async for chunk in request.content.iter_any():
        size += len(chunk)
    return web.Response(body=str(size).encode(), content_type="text/plain")



# -- Postgres and Redis ------------------------------------------------------
# Wired only for the profiles that use them, so both stay None otherwise and the
# handlers answer without touching them. This entry forks one serving process
# per core and each gets its own pool, so the harness's budget is split across
# them rather than opened by each.

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

TLS_CERT = "/certs/server.crt"
TLS_KEY = "/certs/server.key"


async def open_pools(_app):
    global PG_POOL, REDIS
    dsn = os.environ.get("DATABASE_URL")
    if dsn and PG_POOL is None:
        budget = int(os.environ.get("DATABASE_MAX_CONN", "256"))
        # headroom for superuser_reserved_connections, split across the workers
        per = max(1, (budget - 8) // max(1, cpu_count()))
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
        return int(request.query.get(name, fallback))
    except (TypeError, ValueError):
        return fallback


async def async_db(request):
    if PG_POOL is None:
        return web.json_response({"items": [], "count": 0})
    limit = max(1, min(50, _int(request, "limit", 50)))
    try:
        rows = await PG_POOL.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
            _int(request, "min", 10), _int(request, "max", 50), limit,
        )
    except Exception:
        return web.json_response({"items": [], "count": 0})
    items = [_item(r) for r in rows]
    return web.json_response({"items": items, "count": len(items)})


async def crud_list(request):
    if PG_POOL is None:
        return web.json_response({"error": "DB not available"}, status=500)
    category = request.query.get("category") or "electronics"
    page = max(1, _int(request, "page", 1))
    limit = max(1, min(50, _int(request, "limit", 10)))
    try:
        rows = await PG_POOL.fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE category = $1 ORDER BY id "
            "LIMIT $2 OFFSET $3",
            category, limit, (page - 1) * limit,
        )
    except Exception:
        return web.json_response({"error": "query failed"}, status=500)
    items = [_item(r) for r in rows]
    return web.json_response(
        {"items": items, "total": len(items), "page": page, "limit": limit}
    )


async def crud_create(request):
    if PG_POOL is None:
        return web.json_response({"error": "DB not available"}, status=500)
    try:
        body = json.loads(await request.read())
    except Exception:
        return web.json_response({"error": "insert failed"}, status=500)
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
        return web.json_response({"error": "insert failed"}, status=500)
    return web.json_response(
        {
            "id": row["id"], "name": body.get("name"),
            "category": body.get("category"), "price": body.get("price"),
            "quantity": body.get("quantity"),
        },
        status=201,
    )


# Cache-aside on Redis where the harness provides it - crud is the one profile
# that does, and the cache is shared across the forked workers as a per-process
# dict would not be.
async def crud_read(request):
    if PG_POOL is None:
        return web.json_response({"error": "DB not available"}, status=500)
    try:
        item_id = int(request.match_info["item_id"])
    except ValueError:
        return web.Response(status=404)
    key = f"crud:{item_id}"
    if REDIS is not None:
        try:
            hit = await REDIS.get(key)
        except Exception:
            hit = None
        if hit:
            return web.Response(
                body=hit.encode(), content_type="application/json",
                headers={"X-Cache": "HIT"},
            )
    try:
        row = await PG_POOL.fetchrow(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE id = $1 LIMIT 1", item_id
        )
    except Exception:
        return web.json_response({"error": "query failed"}, status=500)
    if row is None:
        return web.Response(status=404)
    body = json.dumps(_item(row))
    if REDIS is not None:
        try:
            await REDIS.set(key, body, px=CRUD_TTL_MS)
        except Exception:
            pass
    return web.Response(
        body=body.encode(), content_type="application/json",
        headers={"X-Cache": "MISS"},
    )


async def crud_update(request):
    if PG_POOL is None:
        return web.json_response({"error": "DB not available"}, status=500)
    try:
        item_id = int(request.match_info["item_id"])
    except ValueError:
        return web.Response(status=404)
    try:
        body = json.loads(await request.read())
    except Exception:
        return web.json_response({"error": "update failed"}, status=500)
    try:
        tag = await PG_POOL.execute(
            "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
            body.get("name", "Updated"), body.get("price", 0),
            body.get("quantity", 0), item_id,
        )
    except Exception:
        return web.json_response({"error": "update failed"}, status=500)
    if tag.endswith(" 0"):
        return web.Response(status=404)
    if REDIS is not None:
        try:
            await REDIS.delete(key := f"crud:{item_id}")
        except Exception:
            pass
    return web.json_response(
        {
            "id": item_id, "name": body.get("name"), "price": body.get("price"),
            "quantity": body.get("quantity"),
        }
    )


# Static bodies are read from disk on every request, which the static profiles
# require in every mode. FileResponse hands back the handle rather than holding
# the bytes; standard mode leaves the encoding to aiohttp's own compression.
async def static_file(request):
    filename = request.match_info["filename"]
    if "/" in filename or ".." in filename:
        return web.Response(status=404)
    path = os.path.join(STATIC_ROOT, filename)
    if not os.path.isfile(path):
        return web.Response(status=404)
    ext = os.path.splitext(filename)[1]
    return web.FileResponse(
        path,
        headers={"Content-Type": MIME_TYPES.get(ext, "application/octet-stream")},
    )


def build_app():
    app = web.Application(client_max_size=MAX_BODY)
    app.router.add_get("/pipeline", pipeline)
    app.router.add_get("/baseline11", baseline11)
    app.router.add_post("/baseline11", baseline11)
    app.router.add_get("/json/{count}", json_items)
    app.router.add_post("/upload", upload)
    app.router.add_get("/baseline2", baseline11)
    app.router.add_get("/async-db", async_db)
    app.router.add_get("/crud/items", crud_list)
    app.router.add_post("/crud/items", crud_create)
    app.router.add_get("/crud/items/{item_id}", crud_read)
    app.router.add_put("/crud/items/{item_id}", crud_update)
    app.router.add_get("/static/{filename}", static_file)
    app.on_startup.append(open_pools)
    return app


def serve():
    loop = uvloop.new_event_loop()
    asyncio.set_event_loop(loop)
    runner = web.AppRunner(build_app(), access_log=None)
    loop.run_until_complete(runner.setup())
    site = web.TCPSite(
        runner, "0.0.0.0", PORT,
        reuse_port=True, backlog=BACKLOG, shutdown_timeout=1.0,
    )
    loop.run_until_complete(site.start())
    # json-tls and static-tls on 8081, the same runner behind TLS. Every forked
    # worker binds it exactly as they all bind 8080, so the listener is spread
    # rather than parked on one process. The harness only mounts /certs for the
    # TLS profiles, so without them it is not opened.
    if os.path.isfile(TLS_CERT) and os.path.isfile(TLS_KEY):
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.load_cert_chain(TLS_CERT, TLS_KEY)
        tls_site = web.TCPSite(
            runner, "0.0.0.0", 8081, ssl_context=ctx,
            reuse_port=True, backlog=BACKLOG, shutdown_timeout=1.0,
        )
        loop.run_until_complete(tls_site.start())
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, loop.stop)
    try:
        loop.run_forever()
    finally:
        loop.run_until_complete(runner.cleanup())


def main():
    # aiohttp runs one event loop on one thread, so multi-core means one
    # process per core. Each worker opens its own SO_REUSEPORT listener and
    # the kernel spreads the connections.
    workers = cpu_count()
    if workers <= 1:
        serve()
        return

    children = []
    for _ in range(workers):
        pid = os.fork()
        if pid == 0:
            serve()
            os._exit(0)
        children.append(pid)

    def stop(signum, frame):
        for pid in children:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    for pid in children:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


if __name__ == "__main__":
    main()
