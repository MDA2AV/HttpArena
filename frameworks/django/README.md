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
| `/upload` | POST | Reads the body and returns the byte count |

## Notes

- URLconf routing with the `int` path converter, async views returning `HttpResponse` / `JsonResponse`
- Compression through `django.middleware.gzip.GZipMiddleware`
- ASGI and not WSGI because the WSGI request drops `Transfer-Encoding: chunked` bodies, which the baseline profile sends
