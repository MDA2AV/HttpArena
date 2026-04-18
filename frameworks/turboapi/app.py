import os
import sys
import multiprocessing
import json

os.environ["TURBO_DISABLE_RATE_LIMITING"] = "1"
os.environ["TURBO_DISABLE_CACHE"] = "1"

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


# -- APP -----------------------------------------------------------------------

from turboapi.request_handler import RequestBodyParser

original_parse_json_body = RequestBodyParser.parse_json_body

def fixed_parse_json_body(body, handler_signature):
    if not body:
        return { }
    if body.startswith(b'{') or body.startswith(b'['):
        return original_parse_json_body(body, handler_signature)
    return { "_BODY_": body.decode(errors="replace") }

RequestBodyParser.parse_json_body = staticmethod(fixed_parse_json_body)

from turboapi import TurboAPI, Request, Path, Query, File, UploadFile, HTTPException
from turboapi.responses import PlainTextResponse, JSONResponse
from turboapi.middleware import GZipMiddleware
from turboapi.staticfiles import StaticFiles

app = TurboAPI()

app.add_middleware(GZipMiddleware, minimum_size=1, compresslevel=5)


# -- Routes ------------------------------------------------------------------

@app.get("/pipeline")
def pipeline():
    return PlainTextResponse(b"ok")


@app.get("/baseline11")
def baseline11(a, b):
    return PlainTextResponse( str( int(a) + int(b) ) )


@app.post("/baseline11")
def baseline11body(a, b, _BODY_):
    return PlainTextResponse( str( int(a) + int(b) + int(_BODY_) ) )


def json_common(count: int, m_val: float):
    global DATASET_ITEMS
    if not DATASET_ITEMS:
        return PlainTextResponse("No dataset", 500)
    try:
        items = [ ]
        for idx, dsitem in enumerate(DATASET_ITEMS):
            if idx >= count:
                break
            item = dict(dsitem)
            item["total"] = dsitem["price"] * dsitem["quantity"] * m_val
            items.append(item)
        return { "items": items, "count": len(items) }
    except Exception:
        return { "items": [ ], "count": 0 }


@app.get("/json/{count}")
def json_endpoint(count, m):
    count = int(count)
    m = float(m)
    return json_common(count, m)


@app.get("/json-comp/{count}")
def json_comp_endpoint(count, m):
    count = int(count)
    m = float(m)
    return json_common(count, m)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080) 
