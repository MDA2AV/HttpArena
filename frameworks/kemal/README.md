# kemal

Kemal on the Crystal `HTTP::Server`, default configuration.

## Stack

- **Language:** Crystal 1.21
- **Framework:** Kemal 1.12
- **Build:** `crystallang/crystal:1.21.0` in release mode, binary shipped on `ubuntu:24.04`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body and returns the byte count |

## Notes

- Routing and path parameters through the Kemal radix tree router
- JSON written straight into the response with `JSON::Builder`, so the items are never held twice
- Compression through the `HTTP::CompressHandler` that `gzip true` installs, with its defaults
- One process per core, all of them accepting on port 8080 with `SO_REUSEPORT`, because a Crystal
  program serves on a single thread
- The worker count is read from the cgroup files first, so both `--cpus` and `--cpuset-cpus` size it
  right, and only falls back to the host core count
- The dataset is read at startup from `DATASET_PATH` or `/data/dataset.json`. A missing file serves
  an empty list instead of stopping the server
- The two POST endpoints read the request stream themselves, so nothing goes through the Kemal param
  parser and the 20 MB uploads are never buffered
