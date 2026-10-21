# Stock nginx from the official image, unmodified: ssl, http_v2 and gzip_static
# are all in the default build. The production-stack edge -- TLS + h2, /static/*
# off disk, and one auth_request per /api/* call against the shared authsvc.
# gateway-h3 keeps Caddy, in ../proxy-h3/, because h3 needs QUIC.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf

# Unused on this profile -- the auth subrequest carries no body and the write
# path's bodies are small enough to stay in memory -- but nginx creates its
# scratch directories at startup, and left to its own defaults it asks for
# /var/lib/nginx/body, which this image does not create. It then refuses to boot
# with "mkdir() ... failed (2: No such file or directory)". Workers drop to the
# nginx user, so the directories have to be owned by it.
RUN mkdir -p /var/lib/nginx/tmp/body /var/lib/nginx/tmp/proxy \
             /var/lib/nginx/tmp/fastcgi /var/lib/nginx/tmp/uwsgi \
             /var/lib/nginx/tmp/scgi \
 && chown -R nginx:nginx /var/lib/nginx

EXPOSE 8443/tcp

CMD ["nginx", "-g", "daemon off;"]
