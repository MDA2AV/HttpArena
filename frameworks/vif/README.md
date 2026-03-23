# Vif — OCaml 5 Web Framework

[Vif](https://github.com/robur-coop/vif) is a simple web framework for OCaml 5
built on [httpcats](https://github.com/robur-coop/httpcats) and the
[Miou](https://github.com/robur-coop/miou) cooperative/preemptive scheduler.

## Key Features

- **Multicore OCaml 5** — takes advantage of domains via Miou
- **httpcats engine** — high-performance HTTP/1.1 and H2 implementation
- **Typed routing** — routes are type-checked at compile time
- **Pure OCaml stack** — TLS, crypto, compression all implemented in OCaml

## Architecture

- Single binary, multicore via Miou domains
- httpcats handles HTTP parsing and connection management
- Gzip compression via decompress (pure OCaml zlib)
- JSON via Yojson, SQLite via sqlite3-ocaml

## Build

```bash
./build.sh
```

## Run

```bash
docker run -p 8080:8080 \
  -v $(pwd)/../../data/dataset.json:/data/dataset.json:ro \
  -v $(pwd)/../../data/dataset-large.json:/data/dataset-large.json:ro \
  httparena-vif
```
