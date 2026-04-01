import os
import sys
import json
import threading
import multiprocessing
import zlib
import sqlite3
import mimetypes
from urllib.parse import parse_qs

import orjson
import psycopg_pool
import psycopg.rows

# -- Dataset and constants --------------------------------------------------------

CPU_COUNT = int(multiprocessing.cpu_count())
WRK_COUNT = min(len(os.sched_getaffinity(0)), 128)

MIME_TYPES = {
    '.css'  : 'text/css',
    '.js'   : 'application/javascript',
    '.html' : 'text/html',
    '.woff2': 'font/woff2',
    '.svg'  : 'image/svg+xml',
    '.webp' : 'image/webp',
    '.json' : 'application/json',
}
STATIC_DIR = '/data/static/'
STATIC_FILES = { }
def load_static_files():
    global STATIC_FILES, STATIC_DIR, MIME_TYPES
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
            content_type = MIME_TYPES.get(ext)
            if content_type is None:
                content_type, encoding = mimetypes.guess_type(full_path)
                if content_type is None:
                    content_type = 'application/octet-stream'
            STATIC_FILES[key] = (data, content_type)

load_static_files()

DB_PATH = "/data/benchmark.db"
DB_AVAILABLE = os.path.exists(DB_PATH)
DB_QUERY = (
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count"
    "  FROM items"
    " WHERE price BETWEEN ? AND ? LIMIT 50"
)

DATABASE_URL = os.environ.get("DATABASE_URL", '')
DATABASE_POOL = None
DATABASE_QUERY = (
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count"
    "  FROM items"
    " WHERE price BETWEEN %s AND %s LIMIT 50"
)
if DATABASE_URL and DATABASE_URL.startswith("postgres://"):
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

# -- SQLite (thread-local) --------------------------------------------------

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

# -- Postgres DB ------------------------------------------------------------

PG_POOL_MIN_SIZE = 2
PG_POOL_MAX_SIZE = 3

def db_close():
    global DATABASE_POOL
    if DATABASE_POOL:
        try:
            DATABASE_POOL.close()
        except Exception:
            pass
    DATABASE_POOL = None

def db_setup():
    global DATABASE_POOL, DATABASE_URL, WRK_COUNT
    db_close()
    if not DATABASE_URL:
        return
    DATABASE_MAX_CONN = os.environ.get("DATABASE_MAX_CONN", None)
    if DATABASE_MAX_CONN:
        avr_pool_size = DATABASE_MAX_CONN * 0.92 / WRK_COUNT
        PG_POOL_MIN_SIZE = int(avr_pool_size + 0.35)
        PG_POOL_MAX_SIZE = int(avr_pool_size + 0.95)
    try:
        DATABASE_POOL = psycopg_pool.ConnectionPool(
            conninfo = DATABASE_URL,
            min_size = max(PG_POOL_MIN_SIZE, 1),
            max_size = max(PG_POOL_MAX_SIZE, 2),
            kwargs = { 'row_factory': psycopg.rows.dict_row },
        )
        #DATABASE_POOL.wait()
    except Exception:
        DATABASE_POOL = None

# -- Helpers ----------------------------------------------------------

DEF_TEXT_HEADERS = [ ( 'Content-Type', 'text/plain; charset=utf-8' ) ]

def text_resp(body: str | bytes, status: int = 200):
    if isinstance(body, str):
        body = body.encode('utf-8')
    return status, DEF_TEXT_HEADERS, body

def json_resp(body, status: int = 200, gzip: bool = False):
    if gzip:
        headers = [ ('Content-Type', 'application/json'), ('Content-Encoding', 'gzip') ]
    else:
        headers = [ ('Content-Type', 'application/json') ]
    if isinstance(body, dict):
        body = orjson.dumps(body)
    if isinstance(body, str):
        body = body.encode('utf-8')
    return status, headers, body

# -- Routes -----------------------------------------------------------

def pipeline(env):
    return text_resp(b'ok')

def baseline11(env):
    req_method = env.get('REQUEST_METHOD', '')
    query_params = parse_qs(env.get('QUERY_STRING', ''))
    total = 0
    for v in query_params.values():
        try:
            total += int(v[0])
        except ValueError:
            pass
    if req_method == "POST":
        wsgi_input = env['wsgi.input']
        body = wsgi_input.read(16000)
        if body:
            try:
                total += int(body.decode().strip())
            except UnicodeDecodeError:
                pass
            except ValueError:
                pass
    return text_resp(str(total))

def baseline2(env):
    query_params = parse_qs(env.get('QUERY_STRING', ''))
    total = 0
    for v in query_params.values():
        try:
            total += int(v[0])
        except ValueError:
            pass
    return text_resp(str(total))

def json_endpoint(env):
    global DATASET_ITEMS
    if not DATASET_ITEMS:
        return text_resp("No dataset", 500)
    items = [ ]
    for d in DATASET_ITEMS:
        item = dict(d)
        item["total"] = round(d["price"] * d["quantity"] * 100) / 100
        items.append(item)
    return json_resp( { "items": items, "count": len(items) } )

def compression_endpoint(env):
    global LARGE_JSON_BUF
    if not LARGE_JSON_BUF:
        return text_resp("No dataset", 500)
    compressed = zlib.compress(LARGE_JSON_BUF, level = 1, wbits = 31)
    return json_resp(compressed, gzip = True)

def db_endpoint(env):
    global DB_AVAILABLE, DB_QUERY
    if not DB_AVAILABLE:
        return json_resp( { "items": [ ], "count": 0 } )
    query_params = parse_qs(env.get('QUERY_STRING', ''))
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

def async_db_endpoint(env):
    global DATABASE_POOL, DATABASE_QUERY
    if not DATABASE_POOL:
        db_setup()
    if not DATABASE_POOL:
        return json_resp( { "items": [ ], "count": 0 } )
    query_params = parse_qs(env.get('QUERY_STRING', ''))
    min_val = float(query_params.get("min", [10])[0])
    max_val = float(query_params.get("max", [50])[0])
    try:
        with DATABASE_POOL.connection() as conn:
            rows = conn.execute(DATABASE_QUERY, (min_val, max_val)).fetchall()
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

def static_file_endpoint(env):
    global STATIC_FILES, STATIC_DIR
    path = env["PATH_INFO"]
    filename = STATIC_DIR + path.removeprefix('/static/')
    entry = STATIC_FILES.get(filename)
    if entry is None:
        return text_resp(b'Not found', status = 404)
    data, ct = entry
    return 200, [ ('Content-Type', ct) ], data


READ_BUF_SIZE = 256*1024

def upload_endpoint(env):
    wsgi_input = env["wsgi.input"]
    content_length = int(env.get("CONTENT_LENGTH", -1))
    size = 0
    if content_length != 0:
        while True:
            to_read = min(READ_BUF_SIZE, content_length - size) if content_length > 0 else READ_BUF_SIZE
            chunk = wsgi_input.read(to_read)
            if not chunk:
                break
            size += len(chunk)
            if content_length > 0 and size >= content_length:
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

def handle_404(env):
    return text_resp(b'Not found', status = 404)

def handle_405(env):
    return text_resp(b'Method Not Allowed', status = 405)

# -- WSGI app -----------------------------------------------------------

HTTP_STATUS = {
    200: '200 OK',
    404: '404 Not Found',
    405: '405 Method Not Allowed',
    500: '500 Internal Server Error',
}

def app(env, start_response):
    global ROUTES, HTTP_STATUS
    req_method = env.get('REQUEST_METHOD', '')
    if req_method not in [ 'GET', 'POST' ]:
        status, headers, body = handle_405(env)
    else:
        path = env["PATH_INFO"]
        if path.startswith('/static/'):
            app_handler = static_file_endpoint
        else:
            app_handler = ROUTES.get(path, handle_404)
        status, headers, body = app_handler(env)
    start_response(HTTP_STATUS.get(status, str(status)), headers)
    return [ body ]

# -----------------------------------------------------------------------

if __name__ == "__main__":
    import fastpysgi

    host = '0.0.0.0'
    port = 8080

    fastpysgi.server.read_buffer_size = READ_BUF_SIZE
    fastpysgi.server.backlog = 16*1024
    fastpysgi.run(app, host, port, workers = WRK_COUNT, loglevel = 0)
