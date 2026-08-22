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
    body = json.dumps({ 'items': items, 'count': len(items) }).encode()
    # json-comp profile: negotiated per request, nothing without Accept-Encoding.
    # bottle ships no response compression of its own, so the encoding is picked
    # here. Tuned mode, so gzip level 1: the arena measures throughput of
    # compressed JSON and a higher level buys bytes nobody counts.
    accept = request.headers.get('Accept-Encoding', '')
    response.content_type = 'application/json'
    if 'gzip' in accept:
        response.add_header('Content-Encoding', 'gzip')
        return gzip.compress(body, 1)
    return body




# -- crud --------------------------------------------------------------------

REDIS = None

CRUD_COLUMNS = (
    "id, name, category, price, quantity, active, tags, rating_score, rating_count"
)

# The crud profile reads and writes the same ids, so a long TTL would answer from
# a copy the writes have already moved past.
CRUD_TTL_MS = 200


def redis_setup():
    global REDIS
    if REDIS is not None:
        return REDIS
    url = os.environ.get("REDIS_URL")
    if not url:
        return None
    try:
        import redis
        REDIS = redis.Redis.from_url(url, decode_responses=True)
    except Exception:
        REDIS = None
    return REDIS


def crud_item(row):
    tags = row['tags']
    return {
        'id'      : row['id'],
        'name'    : row['name'],
        'category': row['category'],
        'price'   : row['price'],
        'quantity': row['quantity'],
        'active'  : row['active'],
        # tags is a JSONB column, so it arrives as text unless a codec is set
        'tags'    : json.loads(tags) if isinstance(tags, str) else tags,
        'rating'  : { 'score': row['rating_score'], 'count': row['rating_count'] },
    }


def query_int(name, fallback):
    try:
        return int(request.query.get(name, fallback))
    except (TypeError, ValueError):
        return fallback


@app.route('/crud/items', method=['GET', 'POST'])
def crud_collection_endpoint():
    global DATABASE_POOL
    response.content_type = 'application/json'
    if not DATABASE_POOL:
        response.status = 500
        return json.dumps({ "error": "DB not available" })
    if request.method == 'POST':
        try:
            body = json.loads(request.body.read())
        except Exception:
            response.status = 500
            return json.dumps({ "error": "insert failed" })
        name = body.get('name', 'New Product')
        price = body.get('price', 0)
        quantity = body.get('quantity', 0)
        try:
            with DATABASE_POOL.connection() as conn:
                row = conn.execute(
                    "INSERT INTO items (id, name, category, price, quantity, active, "
                    "tags, rating_score, rating_count) "
                    "VALUES (%s, %s, %s, %s, %s, true, '[\"bench\"]', 0, 0) "
                    "ON CONFLICT (id) DO UPDATE SET name = %s, price = %s, "
                    "quantity = %s RETURNING id",
                    (body.get('id'), name, body.get('category', 'test'), price,
                     quantity, name, price, quantity),
                ).fetchone()
        except Exception:
            response.status = 500
            return json.dumps({ "error": "insert failed" })
        response.status = 201
        return json.dumps({
            "id": row['id'], "name": body.get('name'),
            "category": body.get('category'), "price": body.get('price'),
            "quantity": body.get('quantity'),
        })
    category = request.query.get('category') or 'electronics'
    page = max(1, query_int('page', 1))
    limit = max(1, min(50, query_int('limit', 10)))
    try:
        with DATABASE_POOL.connection() as conn:
            rows = conn.execute(
                f"SELECT {CRUD_COLUMNS} FROM items WHERE category = %s ORDER BY id "
                "LIMIT %s OFFSET %s",
                (category, limit, (page - 1) * limit),
            ).fetchall()
    except Exception:
        response.status = 500
        return json.dumps({ "error": "query failed" })
    items = [crud_item(r) for r in rows]
    return json.dumps(
        { "items": items, "total": len(items), "page": page, "limit": limit }
    )


# Cache-aside on Redis where the harness provides it - crud is the one profile
# that does, and the cache is shared across the gunicorn workers as a per-worker
# dict would not be.
@app.route('/crud/items/<item_id:int>', method=['GET', 'PUT'])
def crud_item_endpoint(item_id: int):
    global DATABASE_POOL
    response.content_type = 'application/json'
    if not DATABASE_POOL:
        response.status = 500
        return json.dumps({ "error": "DB not available" })
    rds = redis_setup()
    key = "crud:%d" % item_id
    if request.method == 'PUT':
        try:
            body = json.loads(request.body.read())
        except Exception:
            response.status = 500
            return json.dumps({ "error": "update failed" })
        try:
            with DATABASE_POOL.connection() as conn:
                cur = conn.execute(
                    "UPDATE items SET name = %s, price = %s, quantity = %s "
                    "WHERE id = %s",
                    (body.get('name', 'Updated'), body.get('price', 0),
                     body.get('quantity', 0), item_id),
                )
                affected = cur.rowcount
        except Exception:
            response.status = 500
            return json.dumps({ "error": "update failed" })
        if not affected:
            response.status = 404
            return b''
        if rds is not None:
            try:
                rds.delete(key)
            except Exception:
                pass
        return json.dumps({
            "id": item_id, "name": body.get('name'),
            "price": body.get('price'), "quantity": body.get('quantity'),
        })
    if rds is not None:
        try:
            hit = rds.get(key)
        except Exception:
            hit = None
        if hit:
            response.add_header('X-Cache', 'HIT')
            return hit
    try:
        with DATABASE_POOL.connection() as conn:
            row = conn.execute(
                f"SELECT {CRUD_COLUMNS} FROM items WHERE id = %s LIMIT 1", (item_id,)
            ).fetchone()
    except Exception:
        response.status = 500
        return json.dumps({ "error": "query failed" })
    if row is None:
        response.status = 404
        return b''
    body = json.dumps(crud_item(row))
    if rds is not None:
        try:
            rds.set(key, body, px=CRUD_TTL_MS)
        except Exception:
            pass
    response.add_header('X-Cache', 'MISS')
    return body


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

