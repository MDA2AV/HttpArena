import json
import os
import gzip
import sqlite3
import threading
from django.http import HttpResponse, HttpResponseNotAllowed
from django.views.decorators.http import require_http_methods, require_GET

# Load raw dataset for per-request processing
dataset_items = None
dataset_path = os.environ.get('DATASET_PATH', '/data/dataset.json')
try:
    with open(dataset_path) as f:
        dataset_items = json.load(f)
except Exception:
    pass

# Large dataset for compression
large_dataset_items = None
try:
    with open('/data/dataset-large.json') as f:
        large_dataset_items = json.load(f)
except Exception:
    pass

# SQLite
db_available = os.path.exists('/data/benchmark.db')
DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'

_local = threading.local()

def get_db():
    if not hasattr(_local, 'conn'):
        _local.conn = sqlite3.connect('/data/benchmark.db', uri=True)
        _local.conn.execute('PRAGMA mmap_size=268435456')
        _local.conn.row_factory = sqlite3.Row
    return _local.conn


@require_GET
def pipeline(request):
    resp = HttpResponse(b'ok', content_type='text/plain')
    resp['Server'] = 'django'
    return resp


@require_http_methods(["GET", "POST"])
def baseline11(request):
    total = 0
    for v in request.GET.values():
        try:
            total += int(v)
        except ValueError:
            pass
    if request.method == 'POST':
        # Read from wsgi.input directly to handle chunked Transfer-Encoding
        # (Django's request.body checks CONTENT_LENGTH which is absent for chunked)
        content_length = request.META.get('CONTENT_LENGTH')
        if content_length:
            body = request.body
        else:
            body = request.META['wsgi.input'].read()
        if body:
            try:
                total += int(body.strip())
            except ValueError:
                pass
    resp = HttpResponse(str(total), content_type='text/plain')
    resp['Server'] = 'django'
    return resp


@require_GET
def baseline2(request):
    total = 0
    for v in request.GET.values():
        try:
            total += int(v)
        except ValueError:
            pass
    resp = HttpResponse(str(total), content_type='text/plain')
    resp['Server'] = 'django'
    return resp


@require_GET
def json_endpoint(request):
    if json_response_buf:
        resp = HttpResponse(json_response_buf, content_type='application/json')
        resp['Server'] = 'django'
        return resp
    return HttpResponse('No dataset', status=500)


@require_GET
def compression_endpoint(request):
    if large_json_buf:
        compressed = gzip.compress(large_json_buf, compresslevel=1)
        resp = HttpResponse(compressed, content_type='application/json')
        resp['Content-Encoding'] = 'gzip'
        resp['Server'] = 'django'
        return resp
    return HttpResponse('No dataset', status=500)


@require_GET
def db_endpoint(request):
    if not db_available:
        resp = HttpResponse(b'{"items":[],"count":0}', content_type='application/json')
        resp['Server'] = 'django'
        return resp
    min_val = float(request.GET.get('min', 10))
    max_val = float(request.GET.get('max', 50))
    conn = get_db()
    rows = conn.execute(DB_QUERY, (min_val, max_val)).fetchall()
    items = []
    for r in rows:
        items.append({
            'id': r['id'], 'name': r['name'], 'category': r['category'],
            'price': r['price'], 'quantity': r['quantity'], 'active': bool(r['active']),
            'tags': json.loads(r['tags']),
            'rating': {'score': r['rating_score'], 'count': r['rating_count']}
        })
    body = json.dumps({'items': items, 'count': len(items)})
    resp = HttpResponse(body, content_type='application/json')
    resp['Server'] = 'django'
    return resp


@require_http_methods(["POST"])
def upload_endpoint(request):
    # Stream from wsgi.input directly to avoid buffering the entire body
    # Also handles chunked Transfer-Encoding where CONTENT_LENGTH is absent
    content_length = request.META.get('CONTENT_LENGTH')
    stream = request.META['wsgi.input']
    total = 0
    if content_length:
        remaining = int(content_length)
        while remaining > 0:
            chunk = stream.read(min(65536, remaining))
            if not chunk:
                break
            total += len(chunk)
            remaining -= len(chunk)
    else:
        while True:
            chunk = stream.read(65536)
            if not chunk:
                break
            total += len(chunk)
    resp = HttpResponse(str(total), content_type='text/plain')
    resp['Server'] = 'django'
    return resp
 resp


@require_http_methods(["POST"])
def upload_endpoint(request):
    # Stream from wsgi.input directly to avoid buffering the entire body
    # Also handles chunked Transfer-Encoding where CONTENT_LENGTH is absent
    content_length = request.META.get('CONTENT_LENGTH')
    stream = request.META['wsgi.input']
    total = 0
    if content_length:
        remaining = int(content_length)
        while remaining > 0:
            chunk = stream.read(min(65536, remaining))
            if not chunk:
                break
            total += len(chunk)
            remaining -= len(chunk)
    else:
        while True:
            chunk = stream.read(65536)
            if not chunk:
                break
            total += len(chunk)
    resp = HttpResponse(str(total), content_type='text/plain')
    resp['Server'] = 'django'
    return resp
