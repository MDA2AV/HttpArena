---
title: Directory Structure
---

Create a directory under `frameworks/` with your framework's name:

```
frameworks/
  your-framework/
    Dockerfile
    meta.json
    ... (source files)
```

## Dockerfile

The Dockerfile should build and run your server. Containers are started with `--network host`, so bind to:

- **Port 8080** — HTTP/1.1
- **Port 8443** — HTTPS with HTTP/2 and HTTP/3 (if supported)

Example (Go):

```dockerfile
FROM golang:1.22-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o server .

FROM alpine:3.19
COPY --from=build /app/server /server
CMD ["/server"]
```

## Mounted volumes

The benchmark runner mounts these paths into your container (read-only):

| Path | Purpose |
|------|---------|
| `/data/dataset.json` | 50-item dataset for `/json` endpoint |
| `/data/benchmark.db` | SQLite database (100K rows) for `/db` endpoint |
| `/data/static/` | 20 static files (CSS, JS, HTML, fonts, images) |
| `/certs/server.crt` | TLS certificate for HTTPS/H2/H3 |
| `/certs/server.key` | TLS private key for HTTPS/H2/H3 |

All data mounts are provided unconditionally — your container always has access to all files regardless of which profiles it participates in.
