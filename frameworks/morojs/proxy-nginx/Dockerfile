# Stock nginx. It covers gateway-64 only; gateway-h3 uses the same edge with QUIC in ../proxy-h3.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8443/tcp

CMD ["nginx", "-g", "daemon off;"]
