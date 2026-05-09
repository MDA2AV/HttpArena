from web_framework_api import HeavyOperationStatefulExecutor


class Upload(HeavyOperationStatefulExecutor):
    def __init__(self):
        super().__init__()

        self._threshold_size = 5242880
        self._current_size = 0

    def do_post(self, request, response):
        if int(request.get_headers()["Content-Length"]) >= self._threshold_size:
            (dart_part, is_last_packet) = request.get_large_data()

            self._current_size += len(dart_part)

            if is_last_packet:
                response.set_body(f"{self._current_size}")
        else:
            self._current_size = len(request.get_body())

            response.set_body(f"{self._current_size}")
