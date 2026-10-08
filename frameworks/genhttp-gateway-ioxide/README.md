# genhttp-gateway-ioxide

GenHTTP on both sides of the gateway profiles, both running on the
[ioxide](https://github.com/MDA2AV/ioxide) io_uring engine:

- **Proxy:** the [GenHTTP Gateway](https://github.com/Kaliumhexacyanoferrat/GenHTTP.Gateway)
  (`genhttp/gateway:linux-x64`, pinned by digest) configured with `engine: ioxide`
- **Server:** the [`genhttp-ioxide`](../genhttp-ioxide) entry, built from its own Dockerfile unchanged

## Stack

```
h2load ──TLS h2 / QUIC h3──> gateway :8443 ──HTTP/1.1──> genhttp-ioxide :8080
                              /static/* from disk          /baseline2, /json, /async-db
```

| Path | Handled by |
|---|---|
| `/static/*` | Gateway, from `/data/static/` (`content` route) |
| `/baseline2`, `/json/{count}`, `/async-db` | Server, via the gateway's `default` destination |

- The gateway is configured through `proxy/gateway.yaml` (gateway-64: h1 + h2) or
  `proxy/gateway-h3.yaml` (gateway-h3: adds h3), selected by the `CONFIG` build arg.
- The harness certificates are mounted as `/app/certs`, the gateway's certificate root, and
  referenced as PEM files - which is also what ioxide needs for HTTP/3.
- The single host entry is `any`, so requests for `localhost` match without naming it.
- The gateway's plain port is moved to `8000`, since it always opens one and the server owns
  `8080`-`8082`.
- The server gets neither certificates nor the static directory, so it only opens its plaintext
  listeners and leaves `8443` to the gateway.
- `Accept-Encoding` is forwarded upstream, so `/json` is Brotli-compressed by the server.

## CPU split

Even by default - 16 physical cores each (`0-15,64-79` proxy, `16-31,80-95` server). Override
with `PROXY_CPUSET` / `SERVER_CPUSET` to sweep it.
