import os
import sys
import asyncio
import json
import threading
import multiprocessing
import zlib
import sqlite3
from urllib.parse import parse_qs

import orjson
import asyncpg

# -- Dataset and constants --------------------------------------------------------

CPU_COUNT = int(multiprocessing.cpu_count())

DB_PATH = "/data/benchmark.db"
DB_AVAILABLE = os.path.exists(DB_PATH)

DB_QUERY = (
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count"
    "  FROM items"
    " WHERE price BETWEEN ? AND ? LIMIT 50"
)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://bench:bench@localhost:5432/benchmark")
DATABASE_POOL = None
DATABASE_QUERY = """
    SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
    FROM   items
    WHERE  price BETWEEN $1 AND $2
    LIMIT  50
"""
if DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = "postgresql://" + DATABASE_URL[len("postgres://"):]

DATASET_LARGE_PATH = "/data/dataset-large.json"
DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET_ITEMS = None
try:
    with open(DATASET_PATH) as file:
        DATASET_ITEMS = json.load(file)
except Exception:
    pass

# Large dataset for compression (pre-serialised)
LARGE_JSON_BUF: bytes | None = None
try:
    with open(DATASET_LARGE_PATH) as file:
        raw = json.load(file)
    items = [ ]
    for d in raw:
        item = dict(d)
        item["total"] = round(d["price"] * d["quantity"] * 100) / 100
        items.append(item)
    LARGE_JSON_BUF = orjson.dumps( { "items": items, "count": len(items) } )
except Exception:
    pass

# -- SQLite (thread-local, sync — runs in threadpool via run_in_executor) --

_local = threading.local()

def _get_db() -> sqlite3.Connection:
    global _local
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect(DB_PATH, uri = True, check_same_thread = False)
        conn.execute("PRAGMA mmap_size=268435456")
        conn.row_factory = sqlite3.Row
        _local.conn = conn
    return conn

# -- Posgres DB ------------------------------------------------------------

PG_POOL_MIN_SIZE = 2
PG_POOL_MAX_SIZE = 3

class NoResetConnection(asyncpg.Connection):
    __slots__ = ()
    def get_reset_query(self):
        return ""

async def db_close():
    global DATABASE_POOL
    if DATABASE_POOL:
        try:
            await DATABASE_POOL.close()
        except Exception:
            pass
    DATABASE_POOL = None

async def db_setup():
    global DATABASE_POOL, DATABASE_URL, CPU_COUNT
    await db_close()
    max_pool_size = 0
    '''
    max_connections = 0
    try:
        conn = await asyncpg.connect(DATABASE_URL)
        try:
            result = await conn.fetchval("SHOW max_connections;")
            max_connections = int(result)
        finally:
            await conn.close()
    except Exception:
        pass
    if not max_connections:
        return
    max_pool_size = int(max_connections * 0.87 / CPU_COUNT) + 1
    '''
    try:
        DATABASE_POOL = await asyncpg.create_pool(
            dsn = DATABASE_URL,
            min_size = PG_POOL_MIN_SIZE,
            max_size = max(max_pool_size, PG_POOL_MAX_SIZE),
            connection_class = NoResetConnection
        )
    except Exception:
        DATABASE_POOL = None

# -- Helpers ----------------------------------------------------------

DEF_TEXT_HEADERS = [[ b'Content-Type', b'text/plain; charset=utf-8' ]]

def text_resp(body: str | bytes, status: int = 200):
    if isinstance(body, str):
        body = body.encode('utf-8')
    return status, DEF_TEXT_HEADERS, body

def json_resp(body: dict | str, status: int = 200, gzip: bool = False):
    if gzip:
        headers = [[ b'Content-Type', b'application/json'], [ b'Content-Encoding', b'gzip' ]]
    else:
        headers = [[ b'Content-Type', b'application/json' ]]
    if isinstance(body, dict):
        body = orjson.dumps(body)
    if isinstance(body, str):
        body = body.encode('utf-8')
    return status, headers, body

# -- Routes -----------------------------------------------------------

async def pipeline(scope, receive, send):
    return text_resp(b'ok')

async def baseline11(scope, receive, send):
    req_method = scope.get('method', '')
    query_params = parse_qs(scope.get('query_string', b'').decode())
    total = 0
    for v in query_params.values():
        try:
            total += int(v[0])
        except ValueError:
            pass
    if req_method == "POST":
        body = b''
        while True:
            message = await receive()
            body += message.get('body', b'')
            if not message.get('more_body', False):
                break
        if body:
            try:
                total += int(body.decode().strip())
            except UnicodeDecodeError:
                pass
            except ValueError:
                pass
    return text_resp(str(total))

async def baseline2(scope, receive, send):
    query_params = parse_qs(scope.get('query_string', b'').decode())
    total = 0
    for v in query_params.values():
        try:
            total += int(v[0])
        except ValueError:
            pass
    return text_resp(str(total))

async def json_endpoint(scope, receive, send):
    global DATASET_ITEMS
    if not DATASET_ITEMS:
        return text_resp("No dataset", 500)
    items = [ ]
    for d in DATASET_ITEMS:
        item = dict(d)
        item["total"] = round(d["price"] * d["quantity"] * 100) / 100
        items.append(item)
    return json_resp( { "items": items, "count": len(items) } )

async def compression_endpoint(scope, receive, send):
    global LARGE_JSON_BUF
    if LARGE_JSON_BUF is None:
        return text_resp("No dataset", 500)
    compressed = zlib.compress(LARGE_JSON_BUF, level = 1, wbits = 31)
    return json_resp(compressed, gzip = True)

async def db_endpoint(scope, receive, send):
    global DB_AVAILABLE, DB_QUERY
    if not DB_AVAILABLE:
        return json_resp( { "items": [ ], "count": 0 } )
    query_params = parse_qs(scope.get('query_string', b'').decode())
    min_val = float(query_params.get("min", [10])[0])
    max_val = float(query_params.get("max", [50])[0])
    conn = _get_db()
    rows = conn.execute(DB_QUERY, (min_val, max_val)).fetchall()
    items = [ ]
    for row in rows:
        items.append(
            {
                "id"      : row["id"],
                "name"    : row["name"],
                "category": row["category"],
                "price"   : row["price"],
                "quantity": row["quantity"],
                "active"  : bool(row["active"]),
                "tags"    : json.loads(row["tags"]),
                "rating"  : { "score": row["rating_score"], "count": row["rating_count"] },
            }
        )
    return json_resp( { "items": items, "count": len(items) } )

async def async_db_endpoint(scope, receive, send):
    global DATABASE_POOL, DATABASE_QUERY
    if not DATABASE_POOL:
        return json_resp( { "items": [ ], "count": 0 } )
    query_params = parse_qs(scope.get('query_string', b'').decode())
    min_val = float(query_params.get('min', ['10'])[0])
    max_val = float(query_params.get('max', ['50'])[0])
    db_conn = await DATABASE_POOL.acquire()
    try:
        rows = await db_conn.fetch(DATABASE_QUERY, min_val, max_val)
    finally:
        await DATABASE_POOL.release(db_conn)
    items = [
        {
            'id'      : row['id'],
            'name'    : row['name'],
            'category': row['category'],
            'price'   : row['price'],
            'quantity': row['quantity'],
            'active'  : row['active'],
            'tags'    : row['tags'],
            'rating': {
                'score': row['rating_score'],
                'count': row['rating_count'],
            }
        }
        for row in rows
    ]
    return json_resp( { "items": items, "count": len(items) } )

async def upload_endpoint(scope, receive, send):
    size = 0
    while True:
        message = await receive()
        chunk = message.get('body', b'')
        size += len(chunk)
        if not message.get('more_body', False):
            break
    return text_resp(str(size))

ROUTES = {
    '/pipeline': pipeline,
    '/baseline11': baseline11,
    '/baseline2': baseline2,
    '/json': json_endpoint,
    '/compression': compression_endpoint,
    '/db': db_endpoint,
    '/async-db': async_db_endpoint,
    '/upload': upload_endpoint,
}

async def handle_404(scope, receive, send):
    return text_resp(b'Not found', status = 404)

async def handle_405(scope, receive, send):
    return text_resp(b'Method Not Allowed', status = 405)

# -- ASGI app -----------------------------------------------------------

async def app(scope, receive, send):
    global ROUTES
    if scope['type'] == 'lifespan':
        while True:
            message = await receive()
            if message['type'] == 'lifespan.startup':
                await db_setup()
                await send({'type': 'lifespan.startup.complete'})
            elif message['type'] == 'lifespan.shutdown':
                await db_close()
                await send({'type': 'lifespan.shutdown.complete'})
                return
        return
    req_method = scope.get('method', '')
    if req_method not in [ 'GET', 'POST' ]:
        await send( { 'type': 'http.response.start', 'status': 405, 'headers': DEF_TEXT_HEADERS } )
        await send( { 'type': 'http.response.body', 'body': b'Method Not Allowed', 'more_body': False } )
        return
    path = scope['path']
    app_handler = ROUTES.get(path, handle_404)
    status, headers, body = await app_handler(scope, receive, None)
    await send( { 'type': 'http.response.start', 'status': status, 'headers': headers } )
    await send( { 'type': 'http.response.body', 'body': body, 'more_body': False } )

# -----------------------------------------------------------------------

if __name__ == "__main__":
    import fastpysgi

    host = '0.0.0.0'
    port = 8080

    fastpysgi.server.read_buffer_size = 256*1024
    fastpysgi.server.backlog = 4096
    fastpysgi.server.loop_timeout = 1
    fastpysgi.run(app, host, port, workers = CPU_COUNT, loglevel = 0)
