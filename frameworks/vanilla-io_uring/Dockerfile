FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libpq-dev liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 02015a7c (built from source). Master is
# now preferred over the 0.5.1 tag: the codegen regression that forced 0.5.1 (single-
# element array push 4-7x slower, vlang/v#27468) is fixed (vlang/v#27470), and the
# code uses the modern pooled Go-style db.pg (vlang/v#27265). 02015a7c descends from
# cef604a26, so it keeps the Boehm GC free-space-divisor fix (vlang/v#27560, fixes
# vlang/v#27555) that recovers the default-GC throughput regression seen in the
# c0624b2..6c4d26f range (verified ancestor; the c..02015a7c range adds no GC change).
# For a current master commit, `make` bootstraps via the matching vc; if a much later
# rebuild ever fails to bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout 02015a7ce111e4d0cfd5b5d78711ad0db7586936 && \
    make && ln -s /opt/v/v /usr/local/bin/v

# Install the vanilla HTTP server as the `vanilla` module (import vanilla.http_server),
# pinned to a specific commit: reproducible, with NO per-build network call to detect
# changes. The previous approach `ADD`ed the GitHub API main-ref URL to cache-bust when
# main moved, but that hit api.github.com every build and a transient 504/rate-limit
# failed the whole build (MDA2AV/HttpArena#895). Bump this commit to pick up lib fixes.
#
# vanilla main @15bd57e picks up the allocation fixes from a lib-wide audit:
# enghitalo/vanilla#72 (pg_async: read wire ints at offset, drop per-read slices),
# #73 (static_assets: zero-copy conditional-GET/Range parsing) and #74 (TLS: pool the
# per-connection read/response buffers). pg_async#72 is the one that touches this
# backend's async-DB row-decode hot path.
RUN git clone https://github.com/enghitalo/vanilla /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla checkout 15bd57e5ae8cf1383bd386826e48e08a10f6d4b4

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
