from web_framework_api import StatefulExecutor


class Echo(StatefulExecutor):
    """POST /echo returns the request body back verbatim."""

    def do_post(self, request, response):
        # get_body_as_bytes() is the whole body regardless of framing, so a
        # chunked request works without a Content-Length to size it from.
        response.set_body(request.get_body_as_bytes())
