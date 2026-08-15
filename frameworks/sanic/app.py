import gzip
import json
import multiprocessing
import os

from sanic import Sanic
from sanic.response import json as json_response
from sanic.response import text

# Sanic ships no compression middleware, so json-comp is gzipped by hand in the
# response middleware below. 1 KB threshold and level 6 are what koa-compress
# and @fastify/compress use by default, so the entry stays comparable.
MIN_COMPRESS_SIZE = 1024
GZIP_LEVEL = 6

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET_ITEMS = json.load(dataset_file)
except Exception:
    DATASET_ITEMS = []


def cpu_count():
    # cgroup quota first, like koa's getCPUCount: the benchmark caps the
    # container, and the host core count would fork far too many workers.
    try:
        with open("/sys/fs/cgroup/cpu.max") as quota_file:
            quota, period = quota_file.read().split()
        if quota != "max":
            limit = int(quota) // int(period)
            if limit >= 1:
                return limit
    except Exception:
        pass
    try:
        return len(os.sched_getaffinity(0))
    except Exception:
        return multiprocessing.cpu_count() or 1


app = Sanic("httparena")
app.config.ACCESS_LOG = False


@app.get("/pipeline")
async def pipeline(request):
    return text("ok")


@app.route("/baseline11", methods=["GET", "POST"])
async def baseline11(request):
    total = 0
    for values in request.args.values():
        for value in values:
            try:
                total += int(value)
            except (TypeError, ValueError):
                pass
    if request.method == "POST" and request.body:
        try:
            total += int(request.body.strip())
        except (TypeError, ValueError):
            pass
    return text(str(total))


@app.get("/json/<count:int>")
async def json_items(request, count):
    if count < 0:
        count = 0
    elif count > len(DATASET_ITEMS):
        count = len(DATASET_ITEMS)
    try:
        m = int(request.args.get("m", 1))
    except (TypeError, ValueError):
        m = 1
    items = [
        {**item, "total": item["price"] * item["quantity"] * m}
        for item in DATASET_ITEMS[:count]
    ]
    return json_response({"items": items, "count": count})


@app.post("/upload", stream=True)
async def upload(request):
    size = 0
    while True:
        chunk = await request.stream.read()
        if chunk is None:
            break
        size += len(chunk)
    return text(str(size))


@app.on_response
async def compress_response(request, response):
    # Nothing is compressed unless the client negotiated it, so the plain
    # /json profile keeps sending plain JSON on the same route.
    body = response.body
    if not body or len(body) < MIN_COMPRESS_SIZE:
        return
    if "gzip" not in request.headers.get("accept-encoding", ""):
        return
    if response.headers.get("content-encoding"):
        return
    response.body = gzip.compress(body, GZIP_LEVEL)
    response.headers["content-encoding"] = "gzip"
    response.headers["content-length"] = str(len(response.body))
    response.headers["vary"] = "Accept-Encoding"


if __name__ == "__main__":
    # Sanic's own worker manager, not gunicorn: the main process opens the
    # listening socket and hands it to one worker process per core.
    app.run(
        host="0.0.0.0",
        port=8080,
        workers=cpu_count(),
        access_log=False,
        motd=False,
    )
