import json
import os

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.gzip import GZipMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route


# -- Dataset -----------------------------------------------------------------

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET_ITEMS = []
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET_ITEMS = json.load(dataset_file)
except Exception:
    # A missing or broken dataset serves an empty list, it never stops the boot
    pass


# -- Routes ------------------------------------------------------------------

async def pipeline(request: Request):
    return PlainTextResponse(b"ok")


async def baseline11(request: Request):
    total = 0
    for value in request.query_params.values():
        try:
            total += int(value)
        except ValueError:
            pass
    if request.method == "POST":
        body = await request.body()
        if body:
            try:
                total += int(body.strip())
            except ValueError:
                pass
    return PlainTextResponse(str(total))


async def json_items(request: Request):
    count = request.path_params["count"]
    if count < 0:
        count = 0
    if count > len(DATASET_ITEMS):
        count = len(DATASET_ITEMS)
    try:
        m = int(request.query_params.get("m", 1))
    except ValueError:
        m = 1
    items = []
    for dsitem in DATASET_ITEMS[:count]:
        item = dict(dsitem)
        item["total"] = dsitem["price"] * dsitem["quantity"] * m
        items.append(item)
    return JSONResponse({"items": items, "count": count})


async def upload(request: Request):
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
    return PlainTextResponse(str(size))


routes = [
    Route("/pipeline", pipeline, methods=["GET"]),
    Route("/baseline11", baseline11, methods=["GET", "POST"]),
    Route("/json/{count:int}", json_items, methods=["GET"]),
    Route("/upload", upload, methods=["POST"]),
]

# standard mode: gzip is Starlette's own GZipMiddleware, with the settings the
# fastapi entry gives it, so json-comp measures the same middleware on both
middleware = [Middleware(GZipMiddleware, minimum_size=1000, compresslevel=5)]

app = Starlette(routes=routes, middleware=middleware)
