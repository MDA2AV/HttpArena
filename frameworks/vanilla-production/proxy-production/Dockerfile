# Stock nginx: TLS + h2 edge with auth_request for the production-stack profile.
FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8443/tcp

CMD ["nginx", "-g", "daemon off;"]
