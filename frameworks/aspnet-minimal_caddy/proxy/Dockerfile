# Caddy ships HTTP/3 / QUIC support in its stock image — no custom build
# needed, no third-party modules, no source compilation. Point it at a
# Caddyfile and it listens on 8443 for both h2 (TCP) and h3 (UDP).
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8443/tcp 8443/udp

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
