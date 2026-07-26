FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates git build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 84a76d791 (built from source). This is the
# `fasthttp: refactor toward the vanilla architecture` commit (vlang/v#27771): veb now
# runs on the parallel fasthttp backend (one SO_REUSEPORT epoll listener per core, a
# zero-copy append handler, deterministic request framing that reassembles TCP-fragmented
# AND chunked requests, and sendfile(2) static bodies). That reassembly + chunked decode
# is what lets veb subscribe to the baseline profile now (the old single-threaded backend
# could not). It also carries the pooled Go-style `db.pg` (vlang/v#27265) and the Boehm GC
# free-space-divisor fix (vlang/v#27560, fixes vlang/v#27555); cef604a26 (the previous pin)
# is an ancestor. No later master commit touches vlib/veb or vlib/fasthttp, so this pin is
# exactly the modules the server was validated against. `make` bootstraps via the matching
# vc; if a much later rebuild ever fails to bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout 84a76d791 && \
    make && ln -s /opt/v/v /usr/local/bin/v

WORKDIR /app
COPY . .
# Default GC (Boehm) — NOT -prealloc, NOT -gc none. V's -prealloc is a never-free bump
# arena: fine for short-lived programs (the compiler), but a long-running server grows
# unbounded under load (30GiB+ in the arena benchmark). -gc none would leak every
# per-request allocation. Boehm keeps memory bounded; c0624b2's codegen wins still apply.
RUN v -prod . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]
