# Orisha on HttpArena

Koru web framework entry for the HttpArena benchmark suite.

- **Framework:** [Orisha](https://github.com/korulang/orisha) (`import orisha`)
- **Consumer:** `orisha/httparena/` in that repo (this Dockerfile builds it)
- **Ports:** 8080 cleartext, 8081 H1 TLS (validate mounts `/certs`, `/data/dataset.json`)

## Endpoints

| Route | Behavior |
|-------|----------|
| `GET/POST /baseline11` | Sum query values + POST body |
| `GET /pipeline` | `ok` |
| `GET /json/{count}?m=` | Dataset slice, `total = price × quantity × m`, optional gzip |

## Validate

```bash
./scripts/validate.sh orisha
```
