# Stock nginx for gateway-64 (TLS + h2). gateway-h3 uses the Caddy edge in ../proxy-caddy.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8443/tcp

CMD ["nginx", "-g", "daemon off;"]
