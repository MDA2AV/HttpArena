import os
import sys
import json
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
            STATIC_FILES[key] = { "data": data, "type": content_type, "enc": encoding, "ENC": { } }
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
DATABASE_QUERY = (
    "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count"
    "  FROM items"
    " WHERE price BETWEEN %s AND %s LIMIT %s"
)
if DATABASE_URL and DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = "postgresql://" + DATABASE_URL[len("postgres://"):]

PG_POOL_MIN_SIZE = 1
PG_POOL_MAX_SIZE = 2

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
        avr_pool_size = int(DATABASE_MAX_CONN) * 0.92 / WRK_COUNT
        #PG_POOL_MIN_SIZE = int(avr_pool_size + 0.35)
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

def get_path_tail(env):
    path = env["PATH_INFO"]
    xpos = path.rfind('/')
    return path[xpos+1:] if xpos > 0 else ""

def check_accept_encoding(env, substr):
    aenc = env.get('HTTP_ACCEPT_ENCODING', '')
    if aenc and substr == "*":
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
        headers.append( ('Content-Encoding', contenc.lower()) )
    return status, headers, body

def text_resp(body: str | bytes, status: int = 200, contenc: str | None = None):
    return make_resp(status, [ ( 'Content-Type', 'text/plain; charset=utf-8' ) ], body, contenc)

def json_resp(body: dict, status: int = 200, contenc: str | None = None):
    if isinstance(body, dict):
        body = orjson.dumps(body)
    return make_resp(status, [ ('Content-Type', 'application/json') ], body, contenc)

# -- Routes -----------------------------------------------------------

def pipeline(env):
    return 200, [ ( 'Content-Type', 'text/plain; charset=utf-8' ) ], b'ok'

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
    contenc = 'GZIP' if check_accept_encoding(env, 'gzip') else ''
    try:
        count = int(get_path_tail(env))
        query_params = parse_qs(env.get('QUERY_STRING', ''))
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

def async_db_endpoint(env):
    global DATABASE_POOL, DATABASE_QUERY
    if not DATABASE_POOL:
        db_setup()
    if not DATABASE_POOL:
        return json_resp( { "items": [ ], "count": 0 } )
    try:
        query_params = parse_qs(env.get('QUERY_STRING', ''))
        min_val = float(query_params.get("min")[0])
        max_val = float(query_params.get("max")[0])
        lim_val = int(query_params.get("limit")[0])
        with DATABASE_POOL.connection() as conn:
            rows = conn.execute(DATABASE_QUERY, (min_val, max_val, lim_val)).fetchall()
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
    if check_accept_encoding(env, 'br') and 'br' in entry['ENC']:
        entry = STATIC_FILES[entry['ENC']['br']]
    elif check_accept_encoding(env, 'gzip') and 'gzip' in entry['ENC']:
        entry = STATIC_FILES[entry['ENC']['gzip']]
    return make_resp(200, [ ('Content-Type', entry['type']) ], entry['data'], contenc = entry['enc'])


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
    '/json/': json_endpoint,
    '/json-comp/': json_endpoint,
    '/upload': upload_endpoint,
    '/static/': static_file_endpoint,
    '/async-db': async_db_endpoint,
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
        xpos = path.rfind('/')
        xpath = path if xpos <= 0 else path[0:xpos+1]
        app_handler = ROUTES.get(xpath, handle_404)
        status, headers, body = app_handler(env)
    start_response(HTTP_STATUS.get(status, str(status)), headers)
    return [ body ]

# -----------------------------------------------------------------------

if __name__ == "__main__":
    import bjoern

    host = '0.0.0.0'
    port = 8080

    def run_app():
        bjoern.run(app, host, port, reuse_port=True, listen_backlog=16*1024)

    def create_fork():
        n = os.fork()
        # n greater than 0 means parent process
        if n <= 0:
            run_app()

    # fork limiting the threads count - 1
    for i in range(1, WRK_COUNT):
        create_fork()

    run_app()  # run app on the main process too :) 
