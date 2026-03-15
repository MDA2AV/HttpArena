# Build stage
FROM crystallang/crystal:1.14-alpine AS builder

WORKDIR /app

# Install SQLite dev headers and gcc for reuseport shim
RUN apk add --no-cache sqlite-dev sqlite-static gcc musl-dev

# Build SO_REUSEPORT shim
COPY reuseport.c /tmp/reuseport.c
RUN gcc -shared -fPIC -o /tmp/libreuseport.so /tmp/reuseport.c -ldl

# Install dependencies
COPY shard.yml shard.lock ./
RUN shards install --production

# Copy source and build
COPY src/ src/
RUN crystal build src/server.cr -o server --release --no-debug

# Runtime stage
FROM alpine:3.20

RUN apk add --no-cache ca-certificates libgcc gc libevent sqlite-libs pcre2

WORKDIR /app
COPY --from=builder /app/server /app/server
COPY --from=builder /tmp/libreuseport.so /usr/lib/libreuseport.so
COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

EXPOSE 8080

ENV LD_PRELOAD=/usr/lib/libreuseport.so
CMD ["/app/run.sh"]
