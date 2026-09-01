# django

Django 6.1 as an ASGI application on Uvicorn.

## Stack

- **Language:** Python 3.13
- **Framework:** Django 6.1
- **Server:** Uvicorn, one worker per core
- **Build:** `python:3.13-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |
| `/async-db` | GET | Items in a price range, read from Postgres |
| `/crud/items`, `/crud/items/{id}` | GET/POST/PUT | CRUD over Postgres, cache-aside on Redis |
| `/static/{filename}` | GET | Static asset read from `/data/static` per request |
| `/fortunes` | GET | 200 rows from Postgres + a runtime row, sorted and rendered as HTML |

## Notes

- URLconf routing with the `int` path converter, async views returning `HttpResponse` / `JsonResponse`
- Compression through `django.middleware.gzip.GZipMiddleware`
- `/fortunes` renders `templates/fortunes.html` with the Django Template Language on every request, behind the cached loader. Escaping the `<script>` row is DTL's own autoescape, not handler-side work; the sort is Python's code-point ordering, which is the byte order the profile requires
- ASGI and not WSGI because the WSGI request drops `Transfer-Encoding: chunked` bodies, which the baseline profile sends
