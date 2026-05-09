import json
import copy

from typing import Any, Dict

from web_framework_api.web_framework_api import StatelessExecutor


class JsonExecutor(StatelessExecutor):
    def __init__(self):
        super().__init__()

        self._items = None

    def init(self, settings):
        self._items = json.loads(settings.get_file("dataset.json"))

    def do_get(self, request, response):
        multiplier = int(request.get_query_parameters()["m"])
        count = request.get_int_route_parameter("count")
        result: Dict[str, Any] = dict()

        for i in range(count):
            item: Dict[str, Any] = self._items[i]
            temp: Dict[str, Any] = copy.deepcopy(item)

            temp["total"] = int(temp["price"]) * int(temp["quantity"]) * multiplier

            result["items"] = temp

        response.set_body(result)
