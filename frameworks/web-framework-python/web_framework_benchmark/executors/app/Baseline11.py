from typing import Tuple

from web_framework_api import StatelessExecutor, HttpRequest


class Baseline11(StatelessExecutor):
    @staticmethod
    def _parse_values(request: HttpRequest) -> Tuple[int, int]:
        query_parameters = request.get_query_parameters()

        return int(query_parameters["a"]), int(query_parameters["b"])

    def do_get(self, request, response):
        a, b = Baseline11._parse_values(request)

        response.set_body(f"{a + b}")

    def do_post(self, request, response):
        a, b = Baseline11._parse_values(request)
        headers = request.get_headers()

        if "Transfer-Encoding" in headers:
            c = int(request.get_chunks()[0])
        else:
            c = int(request.get_body())

        response.set_body(f"{a + b + c}")
