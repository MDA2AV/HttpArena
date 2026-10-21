FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf

RUN mkdir -p /var/lib/nginx/tmp/body /var/lib/nginx/tmp/proxy \
             /var/lib/nginx/tmp/fastcgi /var/lib/nginx/tmp/uwsgi \
             /var/lib/nginx/tmp/scgi \
 && chown -R nginx:nginx /var/lib/nginx

EXPOSE 8443/tcp

CMD ["nginx", "-g", "daemon off;"]
