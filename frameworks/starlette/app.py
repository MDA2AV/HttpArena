import gzip
import json
import os
import sqlite3
import threading

import orjson
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import Response
from starlette.routing import Route

# ── Dataset ──────────────────────────────────────────────────────────
dataset_items = None
dataset_path = os.environ.get("DATASET_PATH", "/data/dataset.json")
try:
    with open(dataset_path) as f:
        dataset_items = json.load(f)
except Exception:
    pass

# Pre-computed JSON for /json endpoint
json_buf: bytes | None = None
if dataset_items is not None:
    items = []
    for d in dataset_items:
        item = dict(d)
        item["total"] = round(d["price"] * d["quantity"] * 100) / 100
        items.append(item)
    json_buf = orjson.dumps({"items": items, "count": len(items)})

# Large dataset for compression (pre-serialised + pre-compressed)
large_json_buf: bytes | None = None
compressed_buf: bytes | None = None
try:
    with open("/data/dataset-large.json") as f:
        raw = json.load(f)
    items = []
    for d in raw:
        item = dict(d)
        item["total"] = round(d["price"] * d["quantity"] * 100) / 100
        items.append(item)
    large_json_buf = orjson.dumps({"items": items, "count": len(items)})
    compressed_buf = gzip.compress(large_json_buf, compresslevel=1)
except Exception:
    pass

# ── SQLite (thread-local) ────────────────────────────────────────────
db_available = os.path.exists("/data/benchmark.db")
DB_QUERY = (
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count "
    "FROM items WHERE price BETWEEN ? AND ? LIMIT 50"
)
_local = threading.local()


def _get_db() -> sqlite3.Connection:
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect("/data/benchmark.db", uri=True)
        conn.execute("PRAGMA mmap_size=268435456")
        conn.row_factory = sqlite3.Row
        _local.conn = conn
    return conn


# ── Helpers ──────────────────────────────────────────────────────────
SERVER_HEADER = "starlette"


def _text(body: str | bytes, status: int = 200) -> Response:
    return Response(
        content=body,
        status_code=status,
        media_type="text/plain",
        headers={"Server": SERVER_HEADER},
    )


def _json_resp(body: bytes, status: int = 200, extra_headers: dict | None = None) -> Response:
    headers = {"Server": SERVER_HEADER}
    if extra_headers:
        headers.update(extra_headers)
    return Response(content=body, status_code=status, media_type="application/json", headers=headers)


# ── Routes ───────────────────────────────────────────────────────────
async def pipeline(request: Request) -> Response:
    return _text(b"ok")


async def baseline11(request: Request) -> Response:
    total = 0
    for v in request.query_params.values():
        try:
            total += int(v)
        except ValueError:
            pass
    if request.method == "POST":
        body = await request.body()
        if body:
            try:
                total += int(body.strip())
            except ValueError:
                pass
    return _text(str(total))


async def baseline2(request: Request) -> Response:
    total = 0
    for v in request.query_params.values():
        try:
            total += int(v)
        except ValueError:
            pass
    return _text(str(total))


async def json_endpoint(request: Request) -> Response:
    if json_buf is None:
        return _text("No dataset", 500)
    return _json_resp(json_buf)


async def compression_endpoint(request: Request) -> Response:
    if compressed_buf is None:
        return _text("No dataset", 500)
    return _json_resp(compressed_buf, extra_headers={"Content-Encoding": "gzip"})


async def db_endpoint(request: Request) -> Response:
    if not db_available:
        return _json_resp(b'{"items":[],"count":0}')
    min_val = float(request.query_params.get("min", 10))
    max_val = float(request.query_params.get("max", 50))
    conn = _get_db()
    rows = conn.execute(DB_QUERY, (min_val, max_val)).fetchall()
    items = []
    for r in rows:
        items.append(
            {
                "id": r["id"],
                "name": r["name"],
                "category": r["category"],
                "price": r["price"],
                "quantity": r["quantity"],
                "active": bool(r["active"]),
                "tags": json.loads(r["tags"]),
                "rating": {"score": r["rating_score"], "count": r["rating_count"]},
            }
        )
    body = orjson.dumps({"items": items, "count": len(items)})
    return _json_resp(body)


async def upload_endpoint(request: Request) -> Response:
    data = await request.body()
    return _text(str(len(data)))


# ── App ──────────────────────────────────────────────────────────────
routes = [
    Route("/pipeline", pipeline, methods=["GET"]),
    Route("/baseline11", baseline11, methods=["GET", "POST"]),
    Route("/baseline2", baseline2, methods=["GET"]),
    Route("/json", json_endpoint, methods=["GET"]),
    Route("/compression", compression_endpoint, methods=["GET"]),
    Route("/db", db_endpoint, methods=["GET"]),
    Route("/upload", upload_endpoint, methods=["POST"]),
]

app = Starlette(routes=routes)
