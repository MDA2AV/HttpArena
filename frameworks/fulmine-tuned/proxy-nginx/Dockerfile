# Stock nginx. It covers gateway-64 only; gateway-h3 stays on the Caddy image in ../proxy.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8443/tcp

CMD ["nginx", "-g", "daemon off;"]
