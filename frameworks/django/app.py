import json
import os

import django
from django.conf import settings

settings.configure(
    DEBUG=False,
    ALLOWED_HOSTS=["*"],
    SECRET_KEY="httparena",
    ROOT_URLCONF=__name__,
    MIDDLEWARE=["django.middleware.gzip.GZipMiddleware"],
    LOGGING_CONFIG=None,
)
django.setup()

from django.core.asgi import get_asgi_application  # noqa: E402
from django.http import HttpResponse, JsonResponse  # noqa: E402
from django.urls import path  # noqa: E402

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET = []
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET = json.load(dataset_file)
except OSError:
    pass


async def pipeline(request):
    return HttpResponse("ok", content_type="text/plain")


async def baseline11(request):
    total = 0
    for value in request.GET.values():
        try:
            total += int(value)
        except ValueError:
            pass
    if request.method == "POST":
        try:
            total += int(request.body.strip())
        except ValueError:
            pass
    return HttpResponse(str(total), content_type="text/plain")


async def json_items(request, count):
    try:
        m = int(request.GET.get("m", 1))
    except ValueError:
        m = 1
    items = []
    for item in DATASET[:count]:
        processed = dict(item)
        processed["total"] = item["price"] * item["quantity"] * m
        items.append(processed)
    return JsonResponse({"items": items, "count": len(items)})


async def upload(request):
    size = 0
    while True:
        chunk = request.read(262144)
        if not chunk:
            break
        size += len(chunk)
    return HttpResponse(str(size), content_type="text/plain")


urlpatterns = [
    path("pipeline", pipeline),
    path("baseline11", baseline11),
    path("json/<int:count>", json_items),
    path("upload", upload),
]

application = get_asgi_application()
