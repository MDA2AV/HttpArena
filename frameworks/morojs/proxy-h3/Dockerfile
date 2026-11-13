# Stock nginx; the official build carries http_v3_module. The same edge as ../proxy-nginx, with QUIC.
# Caddy was here before: every entry behind it lands at 56-63K at 256 connections with a p99 near
# 800 ms, whatever the backend, while the entries on an nginx QUIC edge run at 175-200K.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf
# run by the image's entrypoint before nginx starts
COPY workers.sh /docker-entrypoint.d/30-workers.sh
RUN chmod +x /docker-entrypoint.d/30-workers.sh

EXPOSE 8443/tcp 8443/udp

CMD ["nginx", "-g", "daemon off;"]
