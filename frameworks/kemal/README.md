# Kemal (Crystal)

Kemal web framework for Crystal language. Crystal is a compiled language with Ruby-like syntax and C-like performance.

## Details

- **Framework:** [Kemal](https://github.com/kemalcr/kemal)
- **Language:** Crystal
- **Server:** Built-in (based on Crystal's HTTP::Server)
- **Build:** Compiled with `--release` optimizations
- **Multi-core:** Fork-based worker processes (one per CPU core)

## Endpoints

| Path          | Method    | Description                        |
|---------------|-----------|------------------------------------|
| /pipeline     | GET       | Returns "ok"                       |
| /baseline11   | GET, POST | Sum of query params (+ body)       |
| /baseline2    | GET       | Sum of query params                |
| /json         | GET       | Process and return dataset as JSON |
| /compression  | GET       | Gzip-compressed large dataset      |
| /db           | GET       | SQLite query with price filtering  |
| /upload       | POST      | Returns body byte length           |
