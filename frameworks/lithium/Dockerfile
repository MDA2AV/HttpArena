FROM debian:trixie-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        g++ ca-certificates curl libssl-dev libboost-context-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# Lithium is header-only and ships a generated single header; pinned by commit
# so a build here is reproducible rather than tracking master.
ARG LITHIUM_REF=master
RUN curl -fsSL -o lithium_http_server.hh \
    "https://raw.githubusercontent.com/matt-42/lithium/${LITHIUM_REF}/single_headers/lithium_http_server.hh"

COPY main.cc ./
RUN g++ -O3 -march=x86-64-v2 -std=c++17 -I. main.cc -o server \
        -lpthread -lssl -lcrypto -lboost_context -ldl

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3t64 libboost-context1.83.0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
EXPOSE 8080 8081
CMD ["/server"]
