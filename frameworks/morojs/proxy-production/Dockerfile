# Stock nginx with the production-stack routing.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8443/tcp

CMD ["nginx", "-g", "daemon off;"]
