# Stock Caddy, which ships h3 in the base image, so no custom build. It covers
# gateway-h3 (QUIC over UDP) only; gateway-64 uses the nginx edge in
# ../proxy-nginx.
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8443/tcp 8443/udp

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
