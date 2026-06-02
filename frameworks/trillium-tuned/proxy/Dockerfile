# Stock Caddy — ships h1/h2/h3 (QUIC) in the base image, no custom build.
# Covers both gateway-64 (h2 over TCP) and gateway-h3 (QUIC over UDP) from
# the same Caddyfile, which binds 8443 on both tcp and udp.
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8443/tcp 8443/udp

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
