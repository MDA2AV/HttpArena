from web_framework_api import StatefulExecutor


class Upload(StatefulExecutor):
    def __init__(self):
        super().__init__()

        self._threshold_size = 102400
        self._current_size = 0

    def do_post(self, request, response):
        if int(request.get_headers()["Content-Length"]) >= self._threshold_size:
            data, is_last_packet = request.get_large_data()

            self._current_size += len(data)

            if is_last_packet:
                response.set_body(f"{self._current_size}")
        else:
            self._current_size = len(request.get_body_as_bytes())

            response.set_body(f"{self._current_size}")
