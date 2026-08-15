import json
import os

from litestar import HttpMethod, Litestar, MediaType, Request, get, post, route
from litestar.config.compression import CompressionConfig

MAX_BODY = 30 * 1024 * 1024

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET_ITEMS = []
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET_ITEMS = json.load(dataset_file)
except Exception:
    pass


@get("/pipeline", media_type=MediaType.TEXT, sync_to_thread=False)
def pipeline() -> str:
    return "ok"


@route(
    "/baseline11",
    http_method=[HttpMethod.GET, HttpMethod.POST],
    media_type=MediaType.TEXT,
    status_code=200,
)
async def baseline11(request: Request) -> str:
    total = 0
    for value in request.query_params.values():
        try:
            total += int(value)
        except (TypeError, ValueError):
            pass
    if request.method == "POST":
        body = await request.body()
        try:
            total += int(body.strip())
        except (TypeError, ValueError):
            pass
    return str(total)


@get("/json/{count:int}", sync_to_thread=False)
def json_items(count: int, m: int = 1) -> dict:
    items = []
    for item in DATASET_ITEMS[:count]:
        processed = dict(item)
        processed["total"] = item["price"] * item["quantity"] * m
        items.append(processed)
    return {"items": items, "count": len(items)}


@post("/upload", media_type=MediaType.TEXT, status_code=200)
async def upload(request: Request) -> str:
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
    return str(size)


app = Litestar(
    route_handlers=[pipeline, baseline11, json_items, upload],
    compression_config=CompressionConfig(backend="gzip"),
    request_max_body_size=MAX_BODY,
    openapi_config=None,
)
