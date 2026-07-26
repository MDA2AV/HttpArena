from web_framework_api import StatelessExecutor


class Pipeline(StatelessExecutor):
    def do_get(self, request, response):
        response.set_body("ok")
