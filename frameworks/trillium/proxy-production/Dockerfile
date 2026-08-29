# Stock Caddy, same base as the gateway edge. h2 over TCP only here — the profile's load
# generator is h2load against 8443/tcp, so no QUIC listener is needed.
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8443/tcp

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
