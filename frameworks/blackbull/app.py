"""BlackBull entrypoint for HttpArena benchmark profiles.

Implements the endpoint contract documented at
https://www.http-arena.com/docs/add-framework/ for the H1 + WebSocket
profiles BlackBull supports today:

  GET  /pipeline                              → text/plain "ok"
  GET  /baseline11?<int=int>&…                → text/plain sum of query ints
  POST /baseline11?<int=int>&…  body=<int>    → text/plain sum
  GET  /json/{count}?m=<float>                → JSON {items, count}
  GET  /json-comp/{count}?m=<float>           → JSON, may be gzipped
  POST /upload          body                  → text/plain byte count
  GET  /ws (Upgrade)                          → echoes frames

Dataset is read from $DATASET_PATH (default /data/dataset.json — the
read-only mount HttpArena's harness provides).

Profiles intentionally NOT implemented:
  - async-db / crud   (no asyncpg integration)
  - *-h3              (no HTTP/3 transport)
  - *-grpc            (no gRPC support)
  - production-stack / gateway / fortunes

The container starts four BlackBull processes via ``launcher.py``:
cleartext on :8080, h2c on :8082, TLS HTTP/1.1 on :8081, TLS HTTP/2
on :8443.  Cleartext also serves h2c via prior-knowledge — BlackBull
negotiates HTTP/2 on first preface bytes.
"""
import argparse
import json
import os
import sys
from http import HTTPMethod
from urllib.parse import parse_qs

# Scheme.websocket is the BlackBull marker used by `@app.route` to
# register the `echo-ws` HttpArena profile handler.
from blackbull.utils import Scheme

# Ensure the BlackBull source tree is importable when the Docker image
# vendors it at /src/BlackBull/.  Local runs use `pip install -e .` so
# this is a no-op then.
_repo_root = os.environ.get('BLACKBULL_SRC', '/src/BlackBull')
if os.path.isdir(_repo_root) and _repo_root not in sys.path:
    sys.path.insert(0, _repo_root)

from blackbull import BlackBull, JSONResponse, Response, read_body
from blackbull.middleware.compression import Compression


# ---------------------------------------------------------------------------
# Dataset
# ---------------------------------------------------------------------------

DATASET_PATH = os.environ.get('DATASET_PATH', '/data/dataset.json')
try:
    with open(DATASET_PATH, 'r') as f:
        DATASET_ITEMS = json.load(f)
except (OSError, ValueError):
    DATASET_ITEMS = []


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = BlackBull()

# HttpArena's json-comp profile expects Accept-Encoding-driven compression.
# BlackBull's Compression middleware picks br > zstd > gzip from the codecs
# the container has installed.  Bodies below min_size (default 100 bytes)
# pass through, so /baseline11 + /pipeline aren't affected.
#
# Diagnostic toggle: BB_NO_COMPRESSION=1 skips registering Compression
# entirely.  Useful for isolating the cost of on-the-fly brotli encoding
# on already-compressed payloads (e.g. .woff2 fonts) that lack a
# precompressed sibling.  Not for benchmark publication — disabling a
# default-on feature breaks the apples-to-apples convention.
if os.environ.get('BB_NO_COMPRESSION', '0') != '1':
    app.use(Compression())

# HttpArena's static profile expects /static/<asset> to serve files from
# /data/static/.  app.static() registers a StaticFiles middleware with the
# URL prefix and source directory; missing files (e.g. when /data/static/
# is unpopulated in a sandbox run) return 404 without breaking other routes.
app.static('/static', os.environ.get('STATIC_DIR', '/data/static/'))

_PIPELINE_BODY = b'ok'
_NO_DATASET = b'No dataset'
_PLAIN = 'text/plain; charset=utf-8'


def _qs(scope):
    raw = scope.get('query_string') or b''
    return parse_qs(raw.decode('latin-1'), keep_blank_values=True)


@app.route(path='/pipeline', methods=[HTTPMethod.GET])
async def pipeline():
    return Response(_PIPELINE_BODY, content_type=_PLAIN)


async def _baseline_handler(scope, receive, send):
    """Shared body for /baseline11 (H/1.1) and /baseline2 (H/2).

    HttpArena uses path-suffix to distinguish the two profiles, but
    the semantics are identical: sum integer query params, add posted
    body if integer, return as text/plain.
    """
    total = 0
    for vals in _qs(scope).values():
        for v in vals:
            try:
                total += int(v)
            except ValueError:
                pass
    if scope['method'] == 'POST':
        body = await read_body(receive)
        if body:
            try:
                total += int(body.strip())
            except ValueError:
                pass
    payload = str(total).encode()
    await send({'type': 'http.response.start', 'status': 200,
                'headers': [(b'content-type', _PLAIN.encode())]})
    await send({'type': 'http.response.body', 'body': payload})


@app.route(path='/baseline11', methods=[HTTPMethod.GET, HTTPMethod.POST])
async def baseline11(scope, receive, send):
    await _baseline_handler(scope, receive, send)


# HttpArena's H/2 baseline profile uses /baseline2 (path suffix
# disambiguates from the H/1.1 /baseline11).  Same semantics.
@app.route(path='/baseline2', methods=[HTTPMethod.GET, HTTPMethod.POST])
async def baseline2(scope, receive, send):
    await _baseline_handler(scope, receive, send)


def _json_payload(count: int, m: float):
    items = []
    for idx, ds in enumerate(DATASET_ITEMS):
        if idx >= count:
            break
        item = dict(ds)
        item['total'] = ds['price'] * ds['quantity'] * m
        items.append(item)
    return {'items': items, 'count': len(items)}


@app.route(path='/json/{count:int}', methods=[HTTPMethod.GET])
async def json_endpoint(count: int, scope):
    if not DATASET_ITEMS:
        return Response(_NO_DATASET, status=500, content_type=_PLAIN)
    try:
        m = float(_qs(scope).get('m', ['0'])[0])
    except ValueError:
        m = 0.0
    return JSONResponse(_json_payload(count, m))


@app.route(path='/json-comp/{count:int}', methods=[HTTPMethod.GET])
async def json_comp_endpoint(count: int, scope):
    # Same payload as /json; the Compression middleware registered
    # at module top wraps the response with gzip / brotli / zstd per
    # the client's Accept-Encoding.
    if not DATASET_ITEMS:
        return Response(_NO_DATASET, status=500, content_type=_PLAIN)
    try:
        m = float(_qs(scope).get('m', ['0'])[0])
    except ValueError:
        m = 0.0
    return JSONResponse(_json_payload(count, m))




# ---------------------------------------------------------------------------
# Postgres and Redis — async-db and crud.
#
# Wired lazily on first use: launcher.py starts one process per listener port
# and there is no startup hook that runs inside each one's event loop. Every
# process gets its own pool, so the harness's budget is divided by the worker
# count with headroom left for superuser_reserved_connections.
# ---------------------------------------------------------------------------

_PG_POOL = None

_ITEM_COLUMNS = (
    'id, name, category, price, quantity, active, tags, rating_score, rating_count'
)

def _worker_count():
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except Exception:
        return 1


async def _pool():
    global _PG_POOL
    if _PG_POOL is None:
        dsn = os.environ.get('DATABASE_URL')
        if not dsn:
            return None
        try:
            import asyncpg
            budget = int(os.environ.get('DATABASE_MAX_CONN', '256'))
            per = max(1, (budget - 8) // _worker_count())
            _PG_POOL = await asyncpg.create_pool(dsn, min_size=1, max_size=per)
        except Exception:
            return None
    return _PG_POOL


def _item(row):
    tags = row['tags']
    return {
        'id': row['id'],
        'name': row['name'],
        'category': row['category'],
        'price': row['price'],
        'quantity': row['quantity'],
        'active': row['active'],
        # tags is a JSONB column, so it arrives as text unless a codec is set
        'tags': json.loads(tags) if isinstance(tags, str) else tags,
        'rating': {'score': row['rating_score'], 'count': row['rating_count']},
    }


def _qs_int(scope, name, fallback):
    try:
        return int(_qs(scope).get(name, [fallback])[0])
    except (TypeError, ValueError):
        return fallback


@app.route(path='/async-db', methods=[HTTPMethod.GET])
async def async_db_endpoint(scope):
    pool = await _pool()
    if pool is None:
        return JSONResponse({'items': [], 'count': 0})
    limit = max(1, min(50, _qs_int(scope, 'limit', 50)))
    try:
        rows = await pool.fetch(
            f'SELECT {_ITEM_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3',
            _qs_int(scope, 'min', 10), _qs_int(scope, 'max', 50), limit,
        )
    except Exception:
        return JSONResponse({'items': [], 'count': 0})
    items = [_item(r) for r in rows]
    return JSONResponse({'items': items, 'count': len(items)})


# crud is not subscribed: the collection route works, but a handler declared with
# a path parameter does not also receive `receive`/`send`, so /crud/items/{id}
# cannot read a PUT body or write its own response. Left out rather than shipped
# half-working.


@app.route(path='/upload', methods=[HTTPMethod.POST])
async def upload_endpoint(scope, receive, send):
    size = 0
    while True:
        msg = await receive()
        if msg['type'] != 'http.request':
            break
        size += len(msg.get('body') or b'')
        if not msg.get('more_body', False):
            break
    payload = str(size).encode()
    await send({'type': 'http.response.start', 'status': 200,
                'headers': [(b'content-type', _PLAIN.encode())]})
    await send({'type': 'http.response.body', 'body': payload})


# Liveness for ``launcher.py``'s readiness probe.
@app.route(path='/healthz', methods=[HTTPMethod.GET])
async def healthz():
    return Response(b'ok', content_type=_PLAIN)


# HttpArena `echo-ws` profile — RFC 6455 WebSocket echo.  First
# message after accept is the receive loop; text frames echo as text,
# binary frames echo as bytes.
@app.route(path='/ws', methods=[HTTPMethod.GET], scheme=Scheme.websocket)
async def ws_echo(scope, receive, send):
    event = await receive()
    if event.get('type') != 'websocket.connect':
        return
    await send({'type': 'websocket.accept'})
    while True:
        event = await receive()
        t = event.get('type', '')
        if t == 'websocket.disconnect':
            break
        if t != 'websocket.receive':
            continue
        text = event.get('text')
        if text is not None:
            await send({'type': 'websocket.send', 'text': text})
        else:
            await send({'type': 'websocket.send',
                        'bytes': event.get('bytes') or b''})


# ---------------------------------------------------------------------------
# Entry point — invoked by launcher.py once per listener port.
# ---------------------------------------------------------------------------

def _parse_args():
    p = argparse.ArgumentParser(description='BlackBull on HttpArena')
    p.add_argument('--port', type=int, required=True)
    p.add_argument('--cert')
    p.add_argument('--key')
    p.add_argument('--workers', type=int, default=None)
    return p.parse_args()


if __name__ == '__main__':
    args = _parse_args()
    # Match peer benchmark posture: access log off (apples-to-apples).
    os.environ.setdefault('BB_ACCESS_LOG', '0')
    # When BB_ACCESS_LOG=1 is opted in (e.g. for diagnostic phase
    # tracing under BB_PHASE_TRACE=1), the access logger needs an
    # explicit INFO handler — BlackBull's default level inheritance
    # leaves ``blackbull.access`` at WARNING (effective), so
    # emit_access_log() is gated off even when cfg.access_log is True.
    # Wire a dedicated stderr handler with propagate=False so the
    # access stream is self-contained and doesn't double-emit through
    # the QueueHandler on the parent 'blackbull' logger.
    if os.environ.get('BB_ACCESS_LOG') == '1':
        import logging as _bb_logging
        _bb_access = _bb_logging.getLogger('blackbull.access')
        _bb_access.setLevel(_bb_logging.INFO)
        _h = _bb_logging.StreamHandler(sys.stderr)
        _h.setLevel(_bb_logging.INFO)
        _h.setFormatter(_bb_logging.Formatter('[ACCESS] %(message)s'))
        _bb_access.addHandler(_h)
        _bb_access.propagate = False
    if args.cert and args.key:
        app.run(port=args.port, certfile=args.cert, keyfile=args.key,
                workers=args.workers)
    else:
        app.run(port=args.port, workers=args.workers)
