import json

from slimeweb import Slime, SlimeTls

app = Slime(__file__)


def load_json_processing_file():
    with open("/data/dataset.json", "r") as file:
        return json.load(file)


JSON_DATASET = load_json_processing_file()


@app.route("/baseline2", method=["GET", "POST"])
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


@app.route("/json/{count}", method="GET")
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


if __name__ == "__main__":
    app.serve(
        host="0.0.0.0",
        port=8443,
        static_path="/data/static",
        https=SlimeTls(cert="/certs/server.crt ", key="/certs/server.key"),
    )
