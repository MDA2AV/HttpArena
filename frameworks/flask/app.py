import os
import sys
import multiprocessing
import json
import gzip
import mimetypes

import psycopg_pool
import psycopg.rows 

from flask import Flask, request, make_response, Response 
from flask import send_from_directory, jsonify


app = Flask(__name__, static_folder = None)
app.config['JSONIFY_PRETTYPRINT_REGULAR'] = False


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

        
# -- flask features ----------------------------------------------------------

@app.after_request
def compress_response(response):
    if response.status_code < 200 or response.status_code in (204, 304, 206):
        return response

    accept_encoding = request.headers.get('Accept-Encoding', '')
    if 'gzip' not in accept_encoding:
        return response

    if response.headers.get('Content-Encoding'):
        return response

    #if response.direct_passthrough:
    #    return response

    if response.content_length == 0:
        return response

    try:
        body = response.get_data()
    except Exception:
        return response

    if isinstance(body, str):
        body = body.encode('utf-8')

    compressed_body = gzip.compress(body, compresslevel = 5)
    new_response = make_response(compressed_body)
    new_response.headers.update(response.headers)
    new_response.headers['Content-Encoding'] = 'gzip'
    new_response.headers.pop('Content-Length', None)
    #new_response.headers['Vary'] = new_response.headers.get('Vary', '') + ', Accept-Encoding'
    return new_response


# -- Routes ------------------------------------------------------------------

@app.route('/pipeline')
def pipeline():
    return b'ok' 


@app.route('/baseline11', methods=['GET', 'POST'])
def baseline11():
    total = 0
    for val in request.args.values():
        try:
            total += int(val)
        except ValueError:
            pass
    if request.method == 'POST' and request.data:
        try:
            total += int(request.data.strip())
        except ValueError:
            pass
    return str(total)


@app.route('/json/<int:count>')
@app.route('/json-comp/<int:count>')
def json_endpoint(count: int):
    global DATASET_ITEMS
    if not DATASET_ITEMS:
        return Response("No dataset", status=500)
    m_val = request.args.get('m', 1, type=float)
    items = [ ]
    for idx, dsitem in enumerate(DATASET_ITEMS):
        if idx >= count:
            break
        item = dict(dsitem)
        item["total"] = dsitem["price"] * dsitem["quantity"] * m_val
        items.append(item)
    return { 'items': items, 'count': len(items) }


@app.route('/async-db')
def async_db_endpoint():
    global DATABASE_POOL
    if not DATABASE_POOL:
        return { "items": [ ], "count": 0 }
    try:
        min_val = request.args.get('min', type=float)
        max_val = request.args.get('max', type=float)
        limit = request.args.get('limit', type=int)
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


@app.route('/upload', methods=['POST'])
def upload_endpoint():
    size = 0
    while True:
        chunk = request.stream.read(256*1024)
        if not chunk:
            break
        size += len(chunk)
    return str(size)


mimetypes.add_type('.woff2', 'font/woff2')
mimetypes.add_type('.webp', 'image/webp')

@app.route('/static/<path:filepath>')
def static_endpoint(filepath):
    return send_from_directory('/data/static', filepath)
