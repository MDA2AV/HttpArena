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
    # Flask defaults a bare body to text/html; the profiles want text/plain.
    response = make_response(b'ok')
    response.content_type = 'text/plain; charset=utf-8'
    return response


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
    response = make_response(str(total))
    response.content_type = 'text/plain; charset=utf-8'
    return response


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


@app.route('/crud/items', methods=['GET', 'POST'])
def crud_collection_endpoint():
    global DATABASE_POOL
    if not DATABASE_POOL:
        return { "error": "DB not available" }, 500
    if request.method == 'POST':
        body = request.get_json(force=True, silent=True)
        if body is None:
            return { "error": "insert failed" }, 500
        name = body.get('name', 'New Product')
        price = body.get('price', 0)
        quantity = body.get('quantity', 0)
        try:
            with DATABASE_POOL.connection() as db_conn:
                row = db_conn.execute(
                    "INSERT INTO items (id, name, category, price, quantity, active, "
                    "tags, rating_score, rating_count) "
                    "VALUES (%s, %s, %s, %s, %s, true, '[\"bench\"]', 0, 0) "
                    "ON CONFLICT (id) DO UPDATE SET name = %s, price = %s, "
                    "quantity = %s RETURNING id",
                    (body.get('id'), name, body.get('category', 'test'), price,
                     quantity, name, price, quantity),
                ).fetchone()
        except Exception:
            return { "error": "insert failed" }, 500
        return {
            "id": row['id'], "name": body.get('name'),
            "category": body.get('category'), "price": body.get('price'),
            "quantity": body.get('quantity'),
        }, 201
    category = request.args.get('category') or 'electronics'
    page = max(1, request.args.get('page', default=1, type=int) or 1)
    limit = request.args.get('limit', default=10, type=int) or 10
    limit = max(1, min(50, limit))
    try:
        with DATABASE_POOL.connection() as db_conn:
            rows = db_conn.execute(
                f"SELECT {CRUD_COLUMNS} FROM items WHERE category = %s ORDER BY id "
                "LIMIT %s OFFSET %s",
                (category, limit, (page - 1) * limit),
            ).fetchall()
    except Exception:
        return { "error": "query failed" }, 500
    items = [crud_item(r) for r in rows]
    return { "items": items, "total": len(items), "page": page, "limit": limit }


# Cache-aside on Redis where the harness provides it - crud is the one profile
# that does, and the cache is shared across the gunicorn workers as a per-worker
# dict would not be.
@app.route('/crud/items/<int:item_id>', methods=['GET', 'PUT'])
def crud_item_endpoint(item_id):
    global DATABASE_POOL
    if not DATABASE_POOL:
        return { "error": "DB not available" }, 500
    rds = redis_setup()
    key = "crud:%d" % item_id
    if request.method == 'PUT':
        body = request.get_json(force=True, silent=True)
        if body is None:
            return { "error": "update failed" }, 500
        try:
            with DATABASE_POOL.connection() as db_conn:
                cur = db_conn.execute(
                    "UPDATE items SET name = %s, price = %s, quantity = %s "
                    "WHERE id = %s",
                    (body.get('name', 'Updated'), body.get('price', 0),
                     body.get('quantity', 0), item_id),
                )
                affected = cur.rowcount
        except Exception:
            return { "error": "update failed" }, 500
        if not affected:
            return Response(status=404)
        if rds is not None:
            try:
                rds.delete(key)
            except Exception:
                pass
        return {
            "id": item_id, "name": body.get('name'),
            "price": body.get('price'), "quantity": body.get('quantity'),
        }
    if rds is not None:
        try:
            hit = rds.get(key)
        except Exception:
            hit = None
        if hit:
            return Response(hit, mimetype='application/json',
                            headers={'X-Cache': 'HIT'})
    try:
        with DATABASE_POOL.connection() as db_conn:
            row = db_conn.execute(
                f"SELECT {CRUD_COLUMNS} FROM items WHERE id = %s LIMIT 1", (item_id,)
            ).fetchone()
    except Exception:
        return { "error": "query failed" }, 500
    if row is None:
        return Response(status=404)
    body = json.dumps(crud_item(row))
    if rds is not None:
        try:
            rds.set(key, body, px=CRUD_TTL_MS)
        except Exception:
            pass
    return Response(body, mimetype='application/json', headers={'X-Cache': 'MISS'})


@app.route('/static/<path:filepath>')
def static_endpoint(filepath):
    return send_from_directory('/data/static', filepath)
