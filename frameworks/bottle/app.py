import os
import sys
import multiprocessing
import json
import gzip
from io import BytesIO 
import mimetypes

import psycopg_pool
import psycopg.rows 

import bottle

bottle.BaseRequest.MEMFILE_MAX = 31*1024*1024

from bottle import Bottle, route, request, response, static_file


app = Bottle()


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
    global DATABASE_POOL, DATABASE_URL, PG_POOL_MIN_SIZE, PG_POOL_MAX_SIZE, WRK_COUNT
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

db_setup()


# -- Bug Fix for chunked body via gunicorn ---------------------------------------------

@app.hook('before_request')
def fix_chunked_body():
    if request.chunked:
        request.environ['HTTP_TRANSFER_ENCODING'] = '_C_H_U_N_K_E_D_'
        body = BytesIO()
        while True:
            chunk = request.environ['wsgi.input'].read(8192)
            if not chunk:
                break
            body.write(chunk)
        size = body.tell()
        body.seek(0)
        request.environ['wsgi.input'] = body
        request.environ['CONTENT_LENGTH'] = size


# -- Routes ------------------------------------------------------------------

@app.get('/pipeline')
def pipeline():
    response.content_type = 'text/plain; charset=utf-8'
    return b'ok' 


@app.route('/baseline11', method=['GET', 'POST'])
def baseline11():
    total = int(request.query.a) + int(request.query.b)
    if request.method == 'POST':
        total += int(request.body.read(100))
    response.content_type = 'text/plain; charset=utf-8'
    return str(total)


@app.get('/json/<count:int>')
def json_endpoint(count: int):
    global DATASET_ITEMS
    if not DATASET_ITEMS:
        response.content_type = 'text/plain; charset=utf-8'
        return "No dataset", 500
    m_val = float(request.query.m)
    items = [ ]
    for idx, dsitem in enumerate(DATASET_ITEMS):
        if idx >= count:
            break
        item = dict(dsitem)
        item["total"] = dsitem["price"] * dsitem["quantity"] * m_val
        items.append(item)
    return { 'items': items, 'count': len(items) }


@app.get('/async-db')
def async_db_endpoint():
    global DATABASE_POOL
    if not DATABASE_POOL:
        return { "items": [ ], "count": 0 }
    try:
        min_val = float(request.query.min)
        max_val = float(request.query.max)
        limit = int(request.query.limit)
        with DATABASE_POOL.connection() as db_conn:
            rows = db_conn.execute(DATABASE_QUERY, (min_val, max_val, limit)).fetchall()
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
        return { "items": items, "count": len(items) }
    except Exception:
        return { "items": [ ], "count": 0 }


@app.post('/upload')
def upload_endpoint():
    size = 0
    try:
        body = request.body
        while True:
            chunk = body.read(256*1024)
            if not chunk:
                break
            size += len(chunk)
    except Exception:
        pass
    response.content_type = 'text/plain; charset=utf-8'
    return str(size)


mimetypes.add_type('.woff2', 'font/woff2')
mimetypes.add_type('.webp', 'image/webp')

@app.route('/static/<filepath:path>')
def send_static_file(filepath):
    return static_file(filepath, root = '/data/static')

