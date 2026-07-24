import os
import sys
import multiprocessing
import json

from robyn import Robyn, Headers, Request, Response, jsonify
from robyn.argument_parser import Config as RobynConfig
from robyn.types import PathParams


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


# -- APP init --------------------------------------------------------------------

class SpecialConfig(RobynConfig):
    def __init__(self):
        super().__init__()
        self.workers = 2
        self.processes = WRK_COUNT
        self.log_level = "ERROR"

app = Robyn(__file__, config = SpecialConfig())

app.set_response_header("server", "Robyn")

app.serve_directory(route = "/static", directory_path = "/data/static")


# -- Routes ------------------------------------------------------------------

@app.get("/pipeline", const=True)  # Const route (cached in Rust for max performance)
def pipeline():
    return "ok"


@app.get("/baseline11")
@app.post("/baseline11")
def baseline11(request: Request):
    total = 0
    total += int(request.query_params.get("a", "0"))
    total += int(request.query_params.get("b", "0"))
    if request.method == "POST":
        body = request.body
        try:
            total += int(body.strip())
        except Exception:
            pass
    return str(total)


@app.get("/json/:count")
def json_endpoint(request: Request):
    global DATASET_ITEMS
    if not DATASET_ITEMS:
        return "No dataset", 500
    try:
        count = int(request.path_params["count"])
        m_val = float(request.query_params.get("m", "0"))
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


@app.post("/upload")
def upload_endpoint(request: Request):
    size = len(request.body)
    return str(size)


# -- APP executor -----------------------------------------------------------

if __name__ == "__main__":
    app.start(host="0.0.0.0", port=8080)

