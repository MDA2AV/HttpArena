import json
import os

import asyncpg as pg
from slimeweb import Slime, SlimeCompression

app = Slime(__file__)


def load_json_processing_file():
    with open("/data/dataset.json", "r") as file:
        return json.load(file)


JSON_DATASET = load_json_processing_file()
QUERY_STMT = """
SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
FROM items
WHERE price BETWEEN $1 AND $2
LIMIT $3
"""
DB_POOL = None


@app.route("/baseline11", method=["GET", "POST"])
def baseline_test(req, resp):
    if req.method == "GET":
        result = 0
        for q_val in req.query.values():
            try:
                result += int(q_val)
            except ValueError:
                pass
        return resp.plain(str(result))
    else:
        result = 0
        for q_val in req.query.values():
            try:
                result += int(q_val)
            except ValueError:
                pass
        try:
            result += int(req.text)
        except ValueError:
            pass
        return resp.plain(str(result))


@app.route("/pipeline", method="GET")
def pipeline_test(req, resp):
    return resp.plain("ok")


# body_size by default it will read 10MB
# setting read_size as 25MB
@app.route("/upload", method="POST", body_size=1024 * 1024 * 25)
def upload_test(req, resp):
    result = len(req.body)
    return resp.plain(str(result))


@app.route(
    "/json/{count}", method="GET", compression=SlimeCompression.All, comp_level=1
)
def json_test(req, resp):
    global JSON_DATASET
    count = int(req.params["count"])
    multiplier = int(req.query["m"])
    result = []
    for data in JSON_DATASET[:count]:
        result.append(
            {
                "id": data["id"],
                "name": data["name"],
                "category": data["category"],
                "price": data["price"],
                "quantity": data["quantity"],
                "active": data["active"],
                "tags": data["tags"],
                "rating": {
                    "score": data["rating"]["score"],
                    "count": data["rating"]["count"],
                },
                "total": data["price"] * data["quantity"] * multiplier,
            }
        )
    return resp.json({"items": result, "count": count})


# Websocket in slime are event driven
@app.websocket("/ws")
def websocket_test(req, resp):
    def echo_me(msg):
        if isinstance(msg, str):
            return resp.send_text(msg)
        else:
            return resp.send_bytes(msg)

    resp.on_message(echo_me)


@app.route("/async-db", method="GET")
async def async_db_test(req, resp):
    global QUERY_STMT, DB_POOL
    if DB_POOL is None:
        return resp.json({"items": [], "count": 0})
    min = int(req.query["min"])
    max = int(req.query["max"])
    limit = int(req.query["limit"])
    result = []
    data_result = None
    async with DB_POOL.acquire() as conn:
        data_result = await conn.fetch(QUERY_STMT, min, max, limit)
    for data in data_result:
        result.append(
            {
                "id": data["id"],
                "name": data["name"],
                "category": data["category"],
                "price": data["price"],
                "quantity": data["quantity"],
                "active": data["active"],
                "tags": json.loads(data["tags"]),
                "rating": {
                    "score": data["rating_score"],
                    "count": data["rating_count"],
                },
            }
        )
    return resp.json({"items": result, "count": len(result)})


@app.start()
async def init():
    global DB_POOL
    try:
        DB_POOL = await pg.create_pool(
            dsn=os.environ["DATABASE_URL"],
            min_size=5,
            max_size=int(os.environ.get("DATABASE_MAX_CONN", 256)),
        )
        print("Pool is created successfully")
    except Exception as e:
        print("Failed to create pool", e)
        DB_POOL = None


if __name__ == "__main__":
    app.serve(host="0.0.0.0", port=8080, static_path="/data/static")
