import json
import os
import subprocess
import sys

import asyncpg as pg
from slimeweb import Slime, SlimeCompression, SlimeTls

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
    result = 0
    for q_val in req.query.values():
        try:
            result += int(q_val)
        except ValueError:
            pass
    if req.method == "POST":
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
    result = [
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
        for data in JSON_DATASET[:count]
    ]

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
    data_result = await DB_POOL.fetch(QUERY_STMT, min, max, limit)
    result = [
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
        for data in data_result
    ]
    return resp.json({"items": result, "count": len(result)})


class NoResetConnection(pg.Connection):
    __slots__ = ()

    def get_reset_query(self):
        return ""


@app.start()
async def init():
    global DB_POOL
    try:
        DB_POOL = await pg.create_pool(
            dsn=os.environ["DATABASE_URL"],
            min_size=5,
            max_size=int(os.environ.get("DATABASE_MAX_CONN", 256)),
            connection_class=NoResetConnection,
        )
        print("Pool is created successfully")
    except Exception as e:
        print("Failed to create pool", e)
        DB_POOL = None


if __name__ == "__main__":
    tls_cert = "/certs/server.crt"
    tls_key = "/certs/server.key"

    # json-tls on 8081. serve() owns an event loop and makes its own listener
    # TLS rather than adding one, so the second port needs a second serve() --
    # and it cannot share this process: asyncpg pools are bound to the loop that
    # created them, so handlers on the other loop fail with "got Future attached
    # to a different loop" and /async-db returns nothing.
    #
    # So the TLS listener is its own process, started without DATABASE_URL so it
    # creates no pool at all. 8081 only carries json-tls, which never touches
    # the database, and the connection budget is left exactly as it was -- the
    # harness runs Postgres with max_connections=256 and this pool already asks
    # for that many.
    #
    # The harness only mounts /certs for the TLS profiles, so on every other
    # profile no child is started.
    if os.environ.get("HTTPARENA_TLS_LISTENER") == "1":
        app.serve(
            host="0.0.0.0",
            port=8081,
            static_path="/data/static",
            https=SlimeTls(cert=tls_cert, key=tls_key),
        )
    else:
        if os.path.exists(tls_cert) and os.path.exists(tls_key):
            child_env = os.environ.copy()
            child_env["HTTPARENA_TLS_LISTENER"] = "1"
            child_env.pop("DATABASE_URL", None)
            subprocess.Popen([sys.executable, __file__], env=child_env)

        app.serve(host="0.0.0.0", port=8080, static_path="/data/static")
