---
title: Directory Structure
seo_title: "Framework Directory Structure"
description: "The files every HttpArena entry provides under frameworks/, and what each one is used for during build, validation and benchmarking."
---

Create a directory under `frameworks/` with your framework's name:

```
frameworks/
  your-framework/
    Dockerfile
    meta.json
    ... (source files)
```

## Pin your base images

A benchmark is only meaningful if it can be re-run, so every `FROM` must name a version. `latest`, `stable`, `nightly` or no tag at all mean two runs months apart measure different software, and the numbers stop being comparable.

```dockerfile
FROM node:22                  # good - major
FROM python:3.13-slim         # good - major.minor
FROM debian:trixie-slim       # good - a Debian release is a version
FROM rust:1.83 AS build       # good
FROM gcr.io/distroless/base-debian12@sha256:…   # good - digest, for images with no version tags

FROM node:latest              # rejected
FROM python                   # rejected (same as :latest)
FROM debian:stable-slim       # rejected - "stable" moves with each Debian release
```

`scripts/validate.sh` enforces this, so a floating tag fails the PR check before a build is spent on it. Patch versions are not required - `3.13` is fine, `3.13.1` is also fine.

## Dockerfile

The Dockerfile should build and run your server. Containers are started with `--network host`, so bind to:

- **Port 8080** - HTTP/1.1
- **Port 8443** - HTTPS with HTTP/2 and HTTP/3 (if supported)

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
| `/data/static/` | 20 static assets (CSS, JS, HTML, fonts, images) - 15 ship with `.gz` and `.br` sibling files for precompression-aware frameworks |
| `/certs/server.crt` | TLS certificate for HTTPS/H2/H3 |
| `/certs/server.key` | TLS private key for HTTPS/H2/H3 |

Postgres (profiles `async-db`, `crud`, `api-4`, `api-16`, and the compose-orchestrated gateway + production-stack) is provided by a separate sidecar container, reachable via the `DATABASE_URL` environment variable - not a mount. Redis (profile `crud`) is similarly reachable via `REDIS_URL`. See [Configuration](../../running-locally/configuration/) for the full env var list.
