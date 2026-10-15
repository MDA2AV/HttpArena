# Stock Caddy, unmodified. The base image already carries h1/h2/h3 (QUIC), so
# one image serves both gateway profiles: the Caddyfile binds 8443 on tcp and
# udp, and gateway-64 only ever reaches the tcp half while gateway-h3 only ever
# reaches the udp one.
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8443/tcp 8443/udp

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
