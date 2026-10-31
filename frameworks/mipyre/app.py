"""mipyre — HTTP Arena submission.

Exposes the endpoints the Arena profiles in meta.json drive (and /ws for
echo-ws, not subscribed yet), with the payloads of the Actix / FastAPI
reference implementations. Every route runs on a sub-interpreter worker (one
per TPC thread); an `async def` route runs on its worker's asyncio loop.
Ports, threads and TLS come from the MIPYRE_* settings launcher.py gives.
"""

import asyncio
import html
import json
import logging
import os
from operator import itemgetter

from mipyre import Mipyre, Request, Response
from mipyre.db import PgPool

# Log benchmark-path errors at WARNING so they surface in the runner log
# but don't flood the tracing subscriber under load. Every broad-except
# site below calls log.warning(..., exc_info=True) so the stack trace is
# preserved instead of silently swallowed — swallowing a traceback to
# hand a 404 / 400 / {} back has been a regular source of "why is
# throughput suddenly tanking?" debugging evenings elsewhere.
log = logging.getLogger("mipyre.arena")


# ---------------------------------------------------------------------------
# Dataset (loaded once at process start)
# ---------------------------------------------------------------------------

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
try:
    with open(DATASET_PATH) as f:
        DATASET_ITEMS = json.load(f)
except Exception:
    # Served empty (the /json endpoints answer with no items), and said so in the log.
    log.warning("dataset %s not loaded; serving it empty", DATASET_PATH, exc_info=True)
    DATASET_ITEMS = []


# ---------------------------------------------------------------------------
# Postgres pool (one per server run, shared by every worker)
# ---------------------------------------------------------------------------

PG_POOL = None
DATABASE_URL = os.environ.get("DATABASE_URL")
if DATABASE_URL:
    try:
        # Arena harness sets DATABASE_MAX_CONN to the total budget; we follow
        # the Actix convention of using the whole pool size on the Rust side.
        max_conn = int(os.environ.get("DATABASE_MAX_CONN", "256"))
        PG_POOL = PgPool.connect(DATABASE_URL, max_connections=max_conn)
    except Exception:
        # Run without the database (each db endpoint answers its no-pool response), and say so in the log.
        log.warning("postgres pool not connected; db endpoints answer without it", exc_info=True)
        PG_POOL = None


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = Mipyre()
# The in-out profile posts 100 KB and validation goes no higher, but the
# engine default of 2.5 MiB is left raised so an oversized body is answered
# rather than 413'd.
app.max_body_size = 25 * 1024 * 1024
# min_size=256 skips tiny bodies (/pipeline "ok", short query params).
# Arena's json-comp rotates through /json/1..50 with pipeline depth 25
# and hundreds of connections — throughput is bounded by compression
# CPU, so pick the cheapest settings that still compress meaningfully:
# gzip level=1 (fastest) wins ~2x speed over level=6 at ~15% worse ratio,
# and brotli quality=0 is the brotli equivalent.
app.enable_compression(min_size=256, brotli_quality=0, gzip_level=1)

# Static serving — Arena harness mounts /data/static/ (static-h2 on :8443,
# static-tls on :8081: the same mount serves every port). `precompressed=True`
# answers from the .br/.gz twins on disk when Accept-Encoding allows; the
# engine's cache follows the disk.
# STATIC_DIR only exists so the app can be checked outside the container.
app.static("/static", os.environ.get("STATIC_DIR", "/data/static"), precompressed=True)

# echo-ws (not subscribed in meta.json) runs up to 16,384 connections, so the
# default cap of 1024 would answer every connection past it with 503.
app.max_websocket_connections = 16384 + 1024

# unary-grpc / unary-grpc-tls: benchmark.BenchmarkService/GetSum, answered by
# the engine in Rust. Opt-in (without it the path is routed like any other
# request and 404s here).
app.enable_grpc_benchmark()


# /pipeline is answered from the accept loop with a pre-built response; no
# Python runs for it.
app.add_fast_response("GET", "/pipeline", b"ok", content_type="text/plain")


def _sum_ab(req) -> int:
    # The baseline profiles send `a` and `b`. `query_param` reads one key off
    # the query string; `query_params` would build a dict per request.
    total = 0
    for v in (req.query_param("a"), req.query_param("b")):
        if v is not None:
            try:
                total += int(v)
            except ValueError:
                pass
    return total


# A `str` return is sent as `text/plain; charset=utf-8`, which the baseline
# validation accepts (text/plain, bare or with a charset); no Response object
# per request.
@app.get("/baseline11")
def baseline11_get(req: "Request"):
    return str(_sum_ab(req))


@app.post("/baseline11")
def baseline11_post(req: "Request"):
    total = _sum_ab(req)
    body = req.body
    if body:
        try:
            total += int(body)  # int() takes ASCII digits as bytes, whitespace stripped
        except ValueError:
            pass
    return str(total)


@app.get("/baseline2")
def baseline2(req: "Request"):
    return str(_sum_ab(req))


# 8gbit: an ordinary sub-interpreter route. The engine reads the whole body
# (Content-Length or chunked) before the handler runs, and the handler hands
# those bytes back. application/octet-stream is never compressed.
@app.post("/echo")
def echo_body(req: "Request"):
    return Response(req.body, content_type="application/octet-stream")


# async (GET /delay/{ms}): an `async def` route runs on its worker's asyncio
# loop, so a pending sleep holds a timer, not a thread; the TPC threads keep
# serving while 32,000 of these wait. The delay is read from the path on every
# request; 0 answers at once.
@app.get("/delay/{ms}")
async def delay(req: "Request"):
    try:
        ms = int(req.params["ms"])
    except ValueError:
        return _BAD_REQUEST
    if ms < 0:
        return _BAD_REQUEST
    if ms:
        await asyncio.sleep(ms / 1000)
    return str(ms)


# echo-ws: GET /ws upgrades, every message comes back as it came (text as
# text, binary as binary) until the client closes. A plain GET /ws without the
# upgrade headers is not routed here and gets 404.
@app.websocket("/ws")
async def ws_echo(ws):
    async for msg in ws:
        try:
            if msg.__class__ is str:
                await ws.send(msg)
            else:
                await ws.send_bytes(msg)
        except ConnectionError:
            # The client closed while its echo was being queued: nothing left to
            # answer, and the connection's end is not an error of this handler.
            return


# Same payload shape + multiplier semantics as Actix/FastAPI reference:
# take the first `count` dataset items, set `total = price * quantity * m`,
# return {"items": [...], "count": N}.
#
# Returning the dict lets mipyre serialize it in Rust (pythonize +
# serde_json) on every request; nothing is cached by URL or parameters
# (HttpArena's tuned rules forbid response caching keyed by URL/params).
@app.get("/json/{count}")
def json_endpoint(req: "Request"):
    try:
        count = int(req.params["count"])
    except (KeyError, ValueError):
        return {"items": [], "count": 0}
    try:
        m = int(req.query_param("m") or "1")
    except ValueError:
        m = 1
    count = max(0, min(count, len(DATASET_ITEMS)))
    items = [
        {**dsitem, "total": dsitem["price"] * dsitem["quantity"] * m}
        for dsitem in DATASET_ITEMS[:count]
    ]
    return {"items": items, "count": count}


# Async DB — mirrors Actix's query against the items table. Each worker
# thread waits for its own fetch with its GIL released; the run's DB runtime
# drives all of them concurrently.
PG_SQL = (
    "SELECT id, name, category, price, quantity, active, tags, "
    "rating_score, rating_count "
    "FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3"
)


@app.get("/async-db")
def async_db_endpoint(req: "Request"):
    if PG_POOL is None:
        return _EMPTY_DB_RESPONSE
    q = req.query_params
    try:
        min_val = int(q.get("min", "10"))
        max_val = int(q.get("max", "50"))
        limit = int(q.get("limit", "50"))
        limit = max(1, min(limit, 50))
    except ValueError:
        log.warning("/async-db: bad query params %r", dict(q), exc_info=True)
        return _EMPTY_DB_RESPONSE
    try:
        rows = PG_POOL.fetch_all(PG_SQL, min_val, max_val, limit)
    except RuntimeError:
        # A failed query raises DatabaseError, a RuntimeError; keep the
        # empty-response contract Arena expects, but don't lose the trace.
        log.warning("/async-db: fetch_all failed", exc_info=True)
        return _EMPTY_DB_RESPONSE
    return _rows_to_payload(rows)


def _rows_to_payload(rows):
    # Hot loop — shaves ~30% per-row Python overhead by reading each
    # column exactly once and skipping the `isinstance(tags, str)` check
    # when PG already returned jsonb as dict/list (the common path).
    items = []
    append = items.append
    for row in rows:
        tags = row["tags"]
        if tags.__class__ is str:
            tags = json.loads(tags)
        append({
            "id": row["id"],
            "name": row["name"],
            "category": row["category"],
            "price": row["price"],
            "quantity": row["quantity"],
            "active": row["active"],
            "tags": tags,
            "rating": {
                "score": row["rating_score"],
                "count": row["rating_count"],
            },
        })
    return {"items": items, "count": len(items)}


# fortunes (GET /fortunes): every request queries the 200 rows, appends the
# runtime row, sorts by message (str order is code point order, which is the
# UTF-8 byte order the profile asks for) and renders the page. Tuned mode allows
# a hand-written emitter; every message goes through html.escape (& < > " ').
# Only the fixed layout around the rows is a constant.
_FORTUNES_SQL = "SELECT id, message FROM fortune"
_FORTUNE_RUNTIME_ROW = (0, "Additional fortune added at request time.")
_FORTUNES_HEAD = (
    "<!DOCTYPE html><html><head><title>Fortunes</title></head><body>"
    "<table><tr><th>id</th><th>message</th></tr>"
)
_FORTUNES_TAIL = "</table></body></html>"


@app.get("/fortunes")
def fortunes(req: "Request"):
    if PG_POOL is None:
        return _NO_DATABASE
    rows = [(r["id"], r["message"]) for r in PG_POOL.fetch_all(_FORTUNES_SQL)]
    rows.append(_FORTUNE_RUNTIME_ROW)
    rows.sort(key=itemgetter(1))
    escape = html.escape
    parts = [_FORTUNES_HEAD]
    append = parts.append
    for fid, message in rows:
        append(f"<tr><td>{fid}</td><td>{escape(message)}</td></tr>")
    append(_FORTUNES_TAIL)
    return Response("".join(parts), content_type="text/html; charset=utf-8")


_EMPTY_DB_RESPONSE = {"items": [], "count": 0}
_NO_DATABASE = Response(
    "DATABASE_URL is not set", status_code=503, content_type="text/plain"
)
_BAD_REQUEST = Response("bad request", status_code=400, content_type="text/plain")


if __name__ == "__main__":
    app.run()
