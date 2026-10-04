FROM perl:5.42-slim AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        make gcc libc6-dev curl ca-certificates zlib1g-dev ragel \
        libssl-dev libnghttp2-dev libwebsockets-dev libpq-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/skaji/cpm/main/cpm > /usr/local/bin/cpm && \
    chmod +x /usr/local/bin/cpm

WORKDIR /app
COPY cpanfile .
RUN cpm install --global Alien::nghttp2 Alien::libwebsockets && \
    cpm install --global

FROM perl:5.42-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libjemalloc2 zlib1g make gcc libc6-dev ragel \
        libssl3t64 libnghttp2-14 libwebsockets19t64 libpq5 && \
    rm -rf /var/lib/apt/lists/*

ENV LD_PRELOAD=libjemalloc.so.2

WORKDIR /app
COPY --from=build /usr/local/lib/perl5 /usr/local/lib/perl5
COPY --from=build /usr/local/bin /usr/local/bin
COPY app.pl .

EXPOSE 8080 8081 8443

CMD ["perl", "app.pl"]
