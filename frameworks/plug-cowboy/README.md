# plug-cowboy

Plug on the Cowboy adapter, without Phoenix.

## Stack

- **Language:** Elixir 1.20 on OTP 29
- **Framework:** Plug with plug_cowboy 2.9
- **Build:** `mix release`, `elixir:1.20-otp-29-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body in chunks and returns the byte count |

## Notes

- Routing and path/query params through `Plug.Router`
- JSON through Jason, encoded per request
- Compression through the `cowboy_compress_h` stream handler
- The dataset is parsed once at startup and kept in `:persistent_term`
