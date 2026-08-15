# hanami

Hanami actions and router on Puma.

## Stack

- **Language:** Ruby 4.0 with YJIT
- **Framework:** Hanami 2.3
- **Server:** Puma 8, one worker per core, jemalloc

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body in chunks and returns the byte count |

## Notes

- One action class per endpoint, routed by the Hanami router
- JSON generated per request, response format set through the action response
- Compression through `Rack::Deflater` in `config.ru`
- The benchmark posts bodies with no Content-Type, which Rack would parse as
  form data, so form parsing is restricted to real form media types
- hanami-router parses every request body as a query string unless it is told
  the body was already parsed, which the 20 MB upload cannot afford, so
  `config.ru` sets that flag
