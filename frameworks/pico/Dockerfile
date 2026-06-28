FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates git build-essential && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit cef604a26 (built from source), keeping the
# V frameworks on one toolchain. `make` bootstraps via the matching vc; if a much
# later rebuild ever fails to bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout cef604a26 && \
    make && ln -s /opt/v/v /usr/local/bin/v

WORKDIR /app
COPY . .
# Default GC (NOT -gc none). picoev is not part of the veb/fasthttp `-prealloc`
# per-request-arena integration, so -prealloc would accumulate memory under load;
# the default garbage collector is the safe choice here.
RUN v -prod . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends util-linux && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
COPY run.sh /run.sh

EXPOSE 8080
CMD ["sh", "/run.sh"]
