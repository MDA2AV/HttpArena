import os
import sys
import asyncio
import json
import multiprocessing
import zlib
import sqlite3
import mimetypes
from urllib.parse import parse_qs

import orjson
import asyncpg

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

STATIC_DIR = '/data/static/'
STATIC_FILES = { }

def load_static_files():
    global STATIC_FILES, STATIC_DIR
    mimetypes.add_type('.woff2' , 'font/woff2')
    mimetypes.add_type('.webp'  , 'image/webp')
    for root, dirs, files in os.walk(STATIC_DIR):
        for filename in files:
            full_path = os.path.join(root, filename)
            key = full_path.replace(os.sep, '/')
            try:
                with open(full_path, 'rb') as file:
                    data = file.read()
            except Exception as e:
                continue
            ext = os.path.splitext(filename)[1]
            content_type, encoding = mimetypes.guess_type(key)
            if content_type is None:
                content_type = 'application/octet-stream'
                encoding = None
            STATIC_FILES[key] = { "data": data, "type": content_type, "TYPE": content_type.encode(), "enc": encoding, "ENC": { } }
            pass
    for key, row in STATIC_FILES.items():
        if row['enc'] is None:
            if key+'.gz' in STATIC_FILES and STATIC_FILES[key+'.gz']['enc'] == 'gzip':
                STATIC_FILES[key]['ENC']['gzip'] = key+'.gz'
            if key+'.br' in STATIC_FILES and STATIC_FILES[key+'.br']['enc'] == 'br':
                STATIC_FILES[key]['ENC']['br'] = key+'.br'

load_static_files()

# -- Postgres DB ------------------------------------------------------------

DATABASE_URL = os.environ.get("DATABASE_URL", '')
DATABASE_POOL = None
DATABASE_QUERY = """
    SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
    FROM   items
    WHERE  price BETWEEN $1 AND $2
    LIMIT  $3
"""
if DATABASE_URL and DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = "postgresql://" + DATABASE_URL[len("postgres://"):]

PG_POOL_MIN_SIZE = 1
PG_POOL_MAX_SIZE = 2

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
    global DATABASE_POOL, DATABASE_URL, WRK_COUNT
    global PG_POOL_MIN_SIZE, PG_POOL_MAX_SIZE
    await db_close()
    if not DATABASE_URL:
        return
    DATABASE_MAX_CONN = os.environ.get("DATABASE_MAX_CONN", None)
    if DATABASE_MAX_CONN:
        avr_pool_size = int(DATABASE_MAX_CONN) * 0.92 / WRK_COUNT
        #PG_POOL_MIN_SIZE = int(avr_pool_size + 0.35)
        PG_POOL_MAX_SIZE = int(avr_pool_size + 0.95)
    try:
        DATABASE_POOL = await asyncpg.create_pool(
            dsn = DATABASE_URL,
            min_size = max(PG_POOL_MIN_SIZE, 1),
            max_size = max(PG_POOL_MAX_SIZE, 2),
            connection_class = NoResetConnection
        )
    except Exception as e:
        DATABASE_POOL = None

# -- Helpers ----------------------------------------------------------

DEF_TEXT_HEADERS = [[ b'Content-Type', b'text/plain; charset=utf-8' ]]

def get_path_tail(scope):
    path = scope["path"]
    xpos = path.rfind('/')
    return path[xpos+1:] if xpos > 0 else ""

def get_header(scope: dict, name: str, def_value: str):
    name = name.lower()
    for hdr_name, value in scope.get("headers", [ ]):
        if hdr_name.decode('latin-1').lower() == name:
            return value.decode('latin-1', errors="replace")
    return def_value

def check_accept_encoding(scope, substr):
    aenc = get_header(scope, 'Accept-Encoding', '')
    if aenc and substr == "":
        return True
    if aenc and substr in aenc:
        return True
    return False

def make_resp(status: int, headers: list, body: str | bytes, contenc: str | None = None):
    if isinstance(body, str):
        body = body.encode('utf-8')
    if contenc and contenc != 'BR':
        if contenc == 'GZIP':
            body = zlib.compress(body, level = 1, wbits = 31)
        headers.append( [ b'Content-Encoding', contenc.lower().encode() ] )
    return status, headers, body

def text_resp(body: str | bytes, status: int = 200, contenc: str | None = None):
    return make_resp(status, [[ b'Content-Type', b'text/plain; charset=utf-8' ]], body, contenc)

def json_resp(body: dict, status: int = 200, contenc: str | None = None):
    if isinstance(body, dict):
        body = orjson.dumps(body)
    return make_resp(status, [[ b'Content-Type', b'application/json' ]], body, contenc)

# -- Routes -----------------------------------------------------------

async def pipeline(scope, receive, send):
    return 200, [[ b'Content-Type', b'text/plain; charset=utf-8']], b'ok'

async def baseline11(scope, receive, send):
    req_method = scope.get('method', '')
    query_params = parse_qs(scope.get('query_string', b'').decode())
    total = 0
    for val in query_params.values():
        total += int(val[0])
    if req_method == "POST":
        message = await receive()
        total += int(message.get('body', b''))
    return text_resp(str(total))

async def json_endpoint(scope, receive, send):
    global DATASET_ITEMS
    if not DATASET_ITEMS:
        return text_resp("No dataset", 500)
    contenc = 'GZIP' if check_accept_encoding(scope, 'gzip') else ''
    try:
        count = int(get_path_tail(scope))
        query_params = parse_qs(scope.get('query_string', b'').decode())
        m_val = float(query_params.get("m")[0])
        items = [ ]
        for idx, dsitem in enumerate(DATASET_ITEMS):
            if idx >= count:
                break
            item = dict(dsitem)
            item["total"] = dsitem["price"] * dsitem["quantity"] * m_val
            items.append(item)
        return json_resp( { "items": items, "count": len(items) }, contenc = contenc)
    except Exception:
        return json_resp( { "items": [ ], "count": 0 }, contenc = contenc)

async def async_db_endpoint(scope, receive, send):
    global DATABASE_POOL, DATABASE_QUERY
    if not DATABASE_POOL:
        return json_resp( { "items": [ ], "count": 0 } )
    try:
        query_params = parse_qs(scope.get('query_string', b'').decode())
        min_val = float(query_params.get('min')[0])
        max_val = float(query_params.get('max')[0])
        lim_val = int(query_params.get("limit")[0])
        db_conn = await DATABASE_POOL.acquire()
        try:
            rows = await db_conn.fetch(DATABASE_QUERY, min_val, max_val, lim_val)
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
                'tags'    : json.loads(row['tags']) if isinstance(row['tags'], str) else row['tags'],
                'rating': {
                    'score': row['rating_score'],
                    'count': row['rating_count'],
                }
            }
            for row in rows
        ]
        return json_resp( { "items": items, "count": len(items) } )
    except Exception:
        return json_resp( { "items": [ ], "count": 0 } )

async def static_file_endpoint(scope, receive, send):
    global STATIC_FILES, STATIC_DIR
    path = scope['path']
    filename = STATIC_DIR + path.removeprefix('/static/')
    entry = STATIC_FILES.get(filename)
    if entry is None:
        return text_resp(b'Not found', status = 404)
    if check_accept_encoding(scope, 'br') and 'br' in entry['ENC']:
        entry = STATIC_FILES[entry['ENC']['br']]
    elif check_accept_encoding(scope, 'gzip') and 'gzip' in entry['ENC']:
        entry = STATIC_FILES[entry['ENC']['gzip']]
    return make_resp(200, [[ b'Content-Type', entry['TYPE'] ]], entry['data'], contenc = entry['enc'])

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
    '/json/': json_endpoint,
    '/json-comp/': json_endpoint,
    '/upload': upload_endpoint,
    '/static/': static_file_endpoint,
    '/async-db': async_db_endpoint,
}

async def handle_404(scope, receive, send):
    return text_resp(b'Not found', status = 404)

async def handle_405(scope, receive, send):
    return text_resp(b'Method Not Allowed', status = 405)

# -- ASGI app -----------------------------------------------------------

async def asgi_lifespan(receive, send):
    while True:
        message = await receive()
        if message['type'] == 'lifespan.startup':
            await db_setup()
            await send({'type': 'lifespan.startup.complete'})
        elif message['type'] == 'lifespan.shutdown':
            await db_close()
            await send({'type': 'lifespan.shutdown.complete'})
            return

async def app(scope, receive, send):
    global ROUTES
    req_type = scope['type']
    if req_type == 'lifespan':
        return await asgi_lifespan(receive, send)
    assert req_type == 'http'
    req_method = scope.get('method', '')
    if req_method not in [ 'GET', 'POST' ]:
        status, headers, body = await handle_405(scope, receive, None)
    else:
        path = scope['path']
        xpos = path.rfind('/')
        xpath = path if xpos <= 0 else path[0:xpos+1]
        app_handler = ROUTES.get(xpath, handle_404)
        status, headers, body = await app_handler(scope, receive, None)
    await send( { 'type': 'http.response.start', 'status': status, 'headers': headers } )
    await send( { 'type': 'http.response.body', 'body': body, 'more_body': False } )

# -----------------------------------------------------------------------

if __name__ == "__main__":
    import fastpysgi

    certfile = os.environ.get("TLS_CERT", "/certs/server.crt")
    keyfile  = os.environ.get("TLS_KEY" , "/certs/server.key")

    fastpysgi.server.delete_all_binds()
    fastpysgi.server.add_bind('0.0.0.0', 8080)
    fastpysgi.server.add_bind('0.0.0.0', 8081, (certfile, keyfile, None))

    fastpysgi.server.read_buffer_size = 256*1024
    fastpysgi.server.max_content_length = 31_000_000
    fastpysgi.server.backlog = 16*1024
    fastpysgi.server.loop_timeout = 1000
    fastpysgi.run(app, workers = WRK_COUNT, loglevel = 0)
