from web_framework_api import *


def on_start():
    print("Server is running...")


if __name__ == '__main__':
    try:
        initialize_web_framework()

        config = Config("config.json")

        threads = os.getenv("THREADS")

        if threads is not None:
            config.override_configuration("threadCount", int(threads) - 8)

        threads = os.getenv("H2THREADS")

        if threads is not None:
            # TODO: HTTP/2.0
            pass

        server = WebFramework(config)

        server.start(True, on_start)
    except WebFrameworkException as e:
        print(e)

        exit(1)
