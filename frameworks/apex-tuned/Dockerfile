FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc make ca-certificates libc6-dev libssl-dev libcjson-dev libbrotli-dev zlib1g-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Makefile ./
COPY src/ ./src/

RUN make -j$(nproc)

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcjson1 libbrotli1 zlib1g libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/server /server

EXPOSE 8080 8081

ENTRYPOINT ["/server"]
