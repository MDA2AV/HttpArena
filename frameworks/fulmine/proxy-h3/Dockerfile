# Stock nginx, its official build has http_v3_module. Same edge as ../proxy-nginx, with QUIC.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf
# run by the image's entrypoint before nginx starts
COPY workers.sh /docker-entrypoint.d/30-workers.sh
RUN chmod +x /docker-entrypoint.d/30-workers.sh

EXPOSE 8443/tcp 8443/udp

CMD ["nginx", "-g", "daemon off;"]
