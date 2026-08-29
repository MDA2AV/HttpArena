"""BlackBull entrypoint for the HttpArena benchmark profiles.

Serves the H1 + WebSocket profiles; crud, *-grpc and *-h3 are not subscribed.
``launcher.py`` starts one process per listener: cleartext :8080 (h2c by
prior knowledge), h2c :8082, TLS HTTP/1.1 :8081, TLS HTTP/2 :8443.
"""
import argparse
import json
import os
import sys
from http import HTTPMethod
from urllib.parse import parse_qs

from blackbull.utils import Scheme

# The image vendors the source at /src/BlackBull; a no-op for local runs.
_repo_root = os.environ.get('BLACKBULL_SRC', '/src/BlackBull')
if os.path.isdir(_repo_root) and _repo_root not in sys.path:
    sys.path.insert(0, _repo_root)

from blackbull import BlackBull, Connection, Depends, JSONResponse, Response

# Older versions serve every other profile; only /ws falls back.
try:
    from blackbull.websocket import WebSocket
except ImportError:                                   # pragma: no cover
    WebSocket = None
from blackbull.middleware.compression import Compression

import db


DATASET_PATH = os.environ.get('DATASET_PATH', '/data/dataset.json')
try:
    with open(DATASET_PATH, 'r') as f:
        DATASET_ITEMS = json.load(f)
except (OSError, ValueError):
    DATASET_ITEMS = []


app = BlackBull()

app.use(Compression())

app.static('/static', os.environ.get('STATIC_DIR', '/data/static/'))

_PIPELINE_BODY = b'ok'
_NO_DATASET = b'No dataset'
_PLAIN = 'text/plain; charset=utf-8'


def _qs(conn: Connection):
    """Parse query string from a Connection into a multi-value dict."""
    raw = conn.query_string or b''
    return parse_qs(raw.decode('latin-1'), keep_blank_values=True)


@app.route(path='/pipeline', methods=[HTTPMethod.GET])
async def pipeline():
    return Response(_PIPELINE_BODY, content_type=_PLAIN)


async def _baseline_handler(conn: Connection):
    """Shared by /baseline11 and /baseline2: sum the integer query params,
    add the body if it is an integer, return text/plain."""
    total = 0
    for vals in _qs(conn).values():
        for v in vals:
            try:
                total += int(v)
            except ValueError:
                pass
    if conn.method == 'POST':
        body = await conn.body()
        if body:
            try:
                total += int(body.strip())
            except ValueError:
                pass
    return Response(str(total).encode(), content_type=_PLAIN)


@app.route(path='/baseline11', methods=[HTTPMethod.GET, HTTPMethod.POST])
async def baseline11(conn: Connection):
    return await _baseline_handler(conn)


@app.route(path='/baseline2', methods=[HTTPMethod.GET, HTTPMethod.POST])
async def baseline2(conn: Connection):
    return await _baseline_handler(conn)


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
async def json_endpoint(count: int, conn: Connection):
    if not DATASET_ITEMS:
        return Response(_NO_DATASET, status=500, content_type=_PLAIN)
    try:
        m = float(_qs(conn).get('m', ['0'])[0])
    except ValueError:
        m = 0.0
    return JSONResponse(_json_payload(count, m))


@app.route(path='/json-comp/{count:int}', methods=[HTTPMethod.GET])
async def json_comp_endpoint(count: int, conn: Connection):
    if not DATASET_ITEMS:
        return Response(_NO_DATASET, status=500, content_type=_PLAIN)
    try:
        m = float(_qs(conn).get('m', ['0'])[0])
    except ValueError:
        m = 0.0
    return JSONResponse(_json_payload(count, m))


@app.route(path='/echo', methods=[HTTPMethod.POST])
async def echo_endpoint(conn: Connection):
    # Collected: the response needs a Content-Length, and a chunked request has
    # none to forward until the body is in.
    chunks = []
    async for chunk in conn.stream():
        chunks.append(chunk)
    return Response(b''.join(chunks), content_type='application/octet-stream')


@app.route(path='/healthz', methods=[HTTPMethod.GET])
async def healthz():
    return Response(b'ok', content_type=_PLAIN)


if WebSocket is not None:
    @app.route(path='/ws', methods=[HTTPMethod.GET], scheme=Scheme.websocket)
    async def ws_echo(ws: WebSocket):
        await ws.accept()
        async for message in ws:
            await ws.send(message)
else:
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


def _int_qs(conn: Connection, name, default):
    """Read an integer query param from a Connection."""
    try:
        return int(_qs(conn).get(name, [str(default)])[0])
    except (ValueError, IndexError):
        return default


@app.route(path='/async-db', methods=[HTTPMethod.GET])
async def async_db_endpoint(req: Connection, db_conn=Depends(db.lease_connection)):
    min_price = _int_qs(req, 'min', 10)
    max_price = _int_qs(req, 'max', 50)
    limit = max(1, min(_int_qs(req, 'limit', 50), 50))
    items = await db.async_db(db_conn, min_price, max_price, limit)
    return JSONResponse({'items': items, 'count': len(items)})



def _parse_args():
    p = argparse.ArgumentParser(description='BlackBull on HttpArena')
    p.add_argument('--port', type=int, required=True)
    p.add_argument('--cert')
    p.add_argument('--key')
    p.add_argument('--workers', type=int, default=None)
    return p.parse_args()


if __name__ == '__main__':
    args = _parse_args()
    os.environ.setdefault('BB_ACCESS_LOG', '0')
    # BB_ACCESS_LOG=1 wires the async queue handler per worker, but not the
    # level; without this the default WARNING drops the INFO access records.
    if os.environ.get('BB_ACCESS_LOG', '0') not in ('0', '', 'false', 'False'):
        import logging as _logging
        _logging.getLogger('blackbull.access').setLevel(_logging.INFO)
    if args.cert and args.key:
        app.run(port=args.port, certfile=args.cert, keyfile=args.key,
                workers=args.workers)
    else:
        app.run(port=args.port, workers=args.workers)
