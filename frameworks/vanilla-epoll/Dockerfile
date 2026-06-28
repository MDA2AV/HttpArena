FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libpq-dev liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 02015a7c (built from source). Moved off
# the 0.5.1 tag: the codegen regression that forced the pin (single-element array
# push 4-7x slower, vlang/v#27468) is fixed (vlang/v#27470), and the vanilla library
# now uses `ArrayFlags.managed` (the buf_view non-marking window) which only exists
# on post-0.5.1 V. `make` bootstraps via the matching vc; if a much later rebuild
# ever fails to bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout 02015a7ce111e4d0cfd5b5d78711ad0db7586936 && \
    make && ln -s /opt/v/v /usr/local/bin/v

# Install the vanilla HTTP server as the `vanilla` module (import vanilla.http_server),
# pinned to a specific commit: reproducible, and with NO per-build network call to
# detect changes. The previous approach `ADD`ed the GitHub API main-ref URL to cache-bust
# whenever main moved, but that hit api.github.com on every build and a transient 504
# (or rate-limit) failed the whole build (MDA2AV/HttpArena#895). To pick up upstream
# library fixes, bump this commit.
#
# vanilla main @15bd57e picks up the allocation fixes from a lib-wide audit:
# enghitalo/vanilla#72 (pg_async: read wire ints at offset, drop per-read slices),
# #73 (static_assets: zero-copy conditional-GET/Range parsing) and #74 (TLS: pool the
# per-connection read/response buffers).
RUN git clone https://github.com/enghitalo/vanilla /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla checkout 15bd57e5ae8cf1383bd386826e48e08a10f6d4b4

WORKDIR /app
COPY . .
RUN v -prod -gc none . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 liburing2 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]
