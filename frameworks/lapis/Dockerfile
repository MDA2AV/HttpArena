FROM openresty/openresty:alpine-fat

RUN apk add --no-cache git make gcc musl-dev openssl-dev && \
    luarocks install lapis

WORKDIR /app
COPY app.lua config.lua nginx.conf ./
RUN mkdir -p logs

ENV LAPIS_ENVIRONMENT=production

EXPOSE 8080
COPY json-tls.conf /app/json-tls.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN mkdir -p /app/tls.d && chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
