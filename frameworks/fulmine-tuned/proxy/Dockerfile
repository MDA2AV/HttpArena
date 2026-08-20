# Stock Caddy, which ships h1/h2/h3 in the base image, so no custom build. It
# covers gateway-64 (h2 over TCP) and gateway-h3 (QUIC over UDP) from the one
# Caddyfile, which binds 8443 on both.
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8443/tcp 8443/udp

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
