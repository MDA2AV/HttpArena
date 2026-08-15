FROM crystallang/crystal:1.21.0 AS build
WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install --production --frozen
COPY src ./src
RUN crystal build src/server.cr -o /app/server --release --no-debug

# Same distribution as the build image, so the binary finds the libraries it
# was linked against. Only the shared libraries Crystal needs, no toolchain.
FROM ubuntu:24.04
RUN apt-get update && \
    apt-get install -y --no-install-recommends libssl3t64 libpcre2-8-0 zlib1g && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
