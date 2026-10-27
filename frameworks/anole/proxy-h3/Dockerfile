# Stock nginx from the official image: ssl, http_v2, http_v3 and gzip_static
# are in its default build.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf
# Run by the image's entrypoint before nginx starts.
COPY workers.sh /docker-entrypoint.d/30-workers.sh

# Scratch directories nginx.conf names, owned by the worker user.
RUN chmod +x /docker-entrypoint.d/30-workers.sh \
 && mkdir -p /var/lib/nginx/tmp/body /var/lib/nginx/tmp/proxy \
             /var/lib/nginx/tmp/fastcgi /var/lib/nginx/tmp/uwsgi /var/lib/nginx/tmp/scgi \
 && chown -R nginx:nginx /var/lib/nginx

EXPOSE 8443/tcp 8443/udp

CMD ["nginx", "-g", "daemon off;"]
