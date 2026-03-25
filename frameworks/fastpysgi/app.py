import os
import sys
import json
import threading
import zlib
import sqlite3
from urllib.parse import parse_qs

import orjson

# -- Dataset ----------------------------------------------------------

dataset_items = None
dataset_path = os.environ.get("DATASET_PATH", "/data/dataset.json")
try:
    with open(dataset_path) as file:
        dataset_items = json.load(file)
except Exception:
    pass

# Large dataset for compression (pre-serialised)
large_json_buf: bytes | None = None
try:
    with open("/data/dataset-large.json") as file:
        raw = json.load(file)
    items = [ ]
    for d in raw:
        item = dict(d)
        item["total"] = round(d["price"] * d["quantity"] * 100) / 100
        items.append(item)
    large_json_buf = orjson.dumps( { "items": items, "count": len(items) } )
except Exception:
    pass

# -- SQLite (thread-local, sync — runs in threadpool via run_in_executor) --

db_available = os.path.exists("/data/benchmark.db")
DB_QUERY = (
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count"
    "  FROM items"
    " WHERE price BETWEEN ? AND ? LIMIT 50"
)
_local = threading.local()

def _get_db() -> sqlite3.Connection:
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect("/data/benchmark.db", uri = True, check_same_thread = False)
        conn.execute("PRAGMA mmap_size=268435456")
        conn.row_factory = sqlite3.Row
        _local.conn = conn
    return conn

# -- Helpers ----------------------------------------------------------

def text_resp(body: str | bytes, status: int = 200):
    headers = [ ( 'Content-Type', 'text/plain; charset=utf-8' ) ]
    if isinstance(body, str):
        body = body.encode('utf-8')
    return status, headers, body

def json_resp(body, status: int = 200, gzip: bool = False):
    headers = [ ( 'Content-Type', 'application/json' ) ]
    if gzip:
        headers.append( ( 'Content-Encoding', 'gzip' ) )
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
    if dataset_items is None:
        return text_resp("No dataset", 500)
    items = [ ]
    for d in dataset_items:
        item = dict(d)
        item["total"] = round(d["price"] * d["quantity"] * 100) / 100
        items.append(item)
    return json_resp( { "items": items, "count": len(items) } )

def compression_endpoint(env):
    if large_json_buf is None:
        return text_resp("No dataset", 500)
    compressed = zlib.compress(large_json_buf, level = 1, wbits = 31)
    return json_resp(compressed, gzip = True)

def db_endpoint(env):
    query_params = parse_qs(env.get('QUERY_STRING', ''))
    if not db_available:
        return json_resp( { "items": [ ], "count": 0 } )
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

routes = {
    '/pipeline': pipeline,
    '/baseline11': baseline11,
    '/baseline2': baseline2,
    '/json': json_endpoint,
    '/compression': compression_endpoint,
    '/db': db_endpoint,
    '/upload': upload_endpoint,
}

def handle_404(env):
    return text_resp(b'Not found', status = 404)

def handle_405(env):
    return text_resp(b'Method Not Allowed', status = 405)

# -- WSGI app -----------------------------------------------------------

http_status = {
    200: '200 OK',
    404: '404 Not Found',
    405: '405 Method Not Allowed',
    500: '500 Internal Server Error',
}

def app(env, start_response):
    global routes
    req_method = env.get('REQUEST_METHOD', '')
    if req_method not in [ 'GET', 'POST' ]:
        status, headers, body = handle_405(env)
    else:
        path = env["PATH_INFO"]    
        app_handler = routes.get(path, handle_404)
        status, headers, body = app_handler(env)
    start_response(http_status.get(status, str(status)), headers)
    return [ body ]

# -----------------------------------------------------------------------

if __name__ == "__main__":
    import multiprocessing
    import fastpysgi

    workers = int(multiprocessing.cpu_count())
    host = '0.0.0.0'
    port = 8080

    def run_app():
        fastpysgi.server.read_buffer_size = READ_BUF_SIZE
        fastpysgi.server.backlog = 4096
        fastpysgi.run(app, host, port, loglevel = 0)
        sys.exit(0)

    processes = [ ]
    # fork limiting the cpu count - 1
    for i in range(1, workers):
        try:
            pid = os.fork()
            if pid == 0:
                run_app()
            else:
                processes.append(pid)
        except OSError as e:
            print("Failed to fork:", e)
            
    # run app on the main process too :)
    run_app()
