ARG GO_VERSION=1.22-bookworm

# Stage 1: build a custom caddy binary with the httparena handler module
# compiled in. xcaddy's `--with module=./local/path` form uses a go.mod
# `replace` under the hood, so the local module path does not need to be
# a real importable URL.
FROM golang:${GO_VERSION} AS build

RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

WORKDIR /src
COPY httparena/ ./httparena/

# xcaddy synthesizes a tiny main package that imports the module by its
# declared path and uses `replace` to point at /src/httparena. The local
# module's go.mod only needs to declare its own path and the caddy/v2
# dependency; xcaddy drives `go build` from there.
RUN mkdir -p /out && \
    xcaddy build v2.8.4 \
      --with github.com/mda2av/httparena-caddy/httparena=/src/httparena \
      --output /out/caddy

# Stage 2: slim runtime. Caddy is a single static-ish binary; we just need
# CA certs for TLS (unused here with auto_https off, but cheap to keep).
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /out/caddy /caddy
COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8080

CMD ["/caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
