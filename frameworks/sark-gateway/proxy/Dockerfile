FROM caddy:2-alpine
COPY Caddyfile /etc/caddy/Caddyfile
EXPOSE 8443/tcp 8443/udp
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
