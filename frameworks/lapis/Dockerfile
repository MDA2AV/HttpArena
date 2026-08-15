FROM openresty/openresty:alpine-fat

RUN apk add --no-cache git make gcc musl-dev openssl-dev && \
    luarocks install lapis

WORKDIR /app
COPY app.lua config.lua nginx.conf ./
RUN mkdir -p logs

ENV LAPIS_ENVIRONMENT=production

EXPOSE 8080
CMD ["openresty", "-p", "/app", "-c", "/app/nginx.conf", "-g", "daemon off;"]
