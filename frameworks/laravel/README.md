# laravel

Laravel 13 served by Laravel Octane on FrankenPHP.

## Stack

- **Language:** PHP 8.5
- **Framework:** Laravel 13
- **Server:** Laravel Octane on FrankenPHP, one worker per core
- **Build:** `dunglas/frankenphp`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

## Notes

- Routes are registered through the `api` group, so no session, no cookies and no CSRF token
- Octane is the runtime Laravel documents for production, so the framework boots once per worker
- Compression comes from the Caddy `encode` directive in the Caddyfile Octane generates
- `post_max_size=0` because PHP otherwise rejects the 20 MB upload profile with 413
