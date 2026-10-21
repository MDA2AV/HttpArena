# Stock Caddy, unmodified. This is the gateway-h3 edge only: the base image
# carries h1/h2/h3 (QUIC) and the Caddyfile binds 8443 on both tcp and udp, of
# which h3 uses the udp half. gateway-64 uses nginx instead, in ../proxy/, for
# the reason recorded in that nginx.conf -- h3 is the profile that cannot
# follow it, because h3 needs QUIC and nginx has no HTTP/3 without a custom
# build against a QUIC library.
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8443/tcp 8443/udp

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
