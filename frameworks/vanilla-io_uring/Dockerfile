FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libpq-dev liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit cef604a26 (built from source). Master is
# now preferred over the 0.5.1 tag: the codegen regression that forced 0.5.1 (single-
# element array push 4-7x slower, vlang/v#27468) is fixed (vlang/v#27470), and the
# code uses the modern pooled Go-style db.pg (vlang/v#27265). cef604a26 also carries
# the Boehm GC free-space-divisor fix (vlang/v#27560, fixes vlang/v#27555) that
# recovers the default-GC throughput regression seen in the c0624b2..6c4d26f range.
# For a current master commit, `make` bootstraps via the matching vc; if a much later
# rebuild ever fails to bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout cef604a26 && \
    make && ln -s /opt/v/v /usr/local/bin/v

# Install the vanilla HTTP server as the `vanilla` module (import vanilla.http_server),
# pinned to a specific commit: reproducible, with NO per-build network call to detect
# changes. The previous approach `ADD`ed the GitHub API main-ref URL to cache-bust when
# main moved, but that hit api.github.com every build and a transient 504/rate-limit
# failed the whole build (MDA2AV/HttpArena#895). Bump this commit to pick up lib fixes.
RUN git clone https://github.com/enghitalo/vanilla /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla checkout 10488d2f55bbb83781f5489836a57ec5745d486a

WORKDIR /app
COPY . .
# Default GC (NOT -gc none, NOT -prealloc): this runs on the vanilla HTTP server's own
# manual buffer management, not the stdlib veb/fasthttp per-request arena.
RUN v -prod . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 liburing2 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]
