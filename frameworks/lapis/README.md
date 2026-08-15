# lapis

Lapis on OpenResty with LuaJIT.

## Stack

- **Language:** Lua (LuaJIT)
- **Framework:** Lapis
- **Server:** OpenResty (`openresty/openresty:alpine-fat`), one worker per core

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body and returns the byte count |

## Notes

- Routing and params through the Lapis application API
- JSON through the Lapis `json` response, encoded by cjson per request
- Compression through the nginx `gzip` directive, as an OpenResty stack does it
- Bodies larger than the body buffer land in a temp file, so `/upload` falls back
  to the file size
