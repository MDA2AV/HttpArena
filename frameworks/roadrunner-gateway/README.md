# roadrunner-gateway

The gateway profiles for [roadrunner](https://github.com/arizona-framework/roadrunner), reported as `roadrunner`.
The server is built from [`frameworks/roadrunner`](../roadrunner); this directory only holds
the compose files and the edge configuration.

## Why a separate entry

`validate.sh` keeps an entry's standalone container running while it brings up
the compose stacks. The main `roadrunner` entry serves h2 and HTTP/3 on 8443
itself, so a stack in the same entry could not bind its edge there. A
compose-only entry gets the ports to itself.

## gateway-64

- **proxy:** stock `nginx:1.27-alpine`. Terminates TLS and h2 on 8443, serves
  `/static/*` from `/data/static` with `gzip_static`, and proxies `/baseline2`,
  `/json` and `/async-db` to `127.0.0.1:8080` over HTTP/1.1 keepalive
- **server:** roadrunner with no certificates, so it listens in cleartext only
- CPU split 8/24 physical cores, the profile's own example; override with
  `PROXY_CPUSET` and `SERVER_CPUSET`

## gateway-h3

- **proxy:** stock `caddy:2-alpine`. Terminates TLS on 8443 with h1, h2 and h3,
  serves `/static/*` with precompressed `.br`/`.gz` sidecars, and proxies
  everything else to `127.0.0.1:8080` over HTTP/1.1 keepalive
- **server:** the same roadrunner server
- CPU split 16/16 physical cores; override with `PROXY_CPUSET` and
  `SERVER_CPUSET`

## production-stack

- **edge:** stock `nginx:1.27-alpine`. TLS and h2 on 8443, `/static/*` from
  disk, `/public/*` straight to the server, `/api/*` through `auth_request` to
  the shared authsvc on every call
- **cache:** `redis:7-alpine` with the seed entrypoint and a health check
- **authsvc:** built unmodified from `frameworks/_shared/authsvc`
- **server:** roadrunner, cache-aside in process (an ETS table, 1 s TTL for
  items, 30 s for users) over epgsql; `POST /api/items/{id}` updates the row
  and drops the cached item
- CPU split edge 15, cache 1, authsvc 4, server 12 physical cores, the
  profile's reference split; override with `EDGE_CPUSET`, `CACHE_CPUSET`,
  `AUTH_CPUSET` and `SERVER_CPUSET`
