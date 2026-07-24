FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates git build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 84a76d791 (built from source). This is the
# `fasthttp: refactor toward the vanilla architecture` commit (vlang/v#27771): it adds
# the zero-copy append handler (write the raw response straight into the connection's
# reused buffer), per-worker lock-free state (make_state), deterministic request framing
# (TCP-fragmented + chunked reassembly), and sendfile(2) file bodies — the API this
# server is now built on. It also carries everything the previous cef604a26 pin did: the
# pooled Go-style `db.pg` (vlang/v#27265), the single-element-array-push codegen fix
# (vlang/v#27470), and the Boehm GC free-space-divisor fix (vlang/v#27560, fixes
# vlang/v#27555) — cef604a26 is an ancestor of this commit. No later master commit
# touches vlib/fasthttp, so this pin is exactly the module the server was validated
# against. `make` bootstraps via the matching vc; if a much later rebuild ever fails to
# bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout 84a76d791 && \
    make && ln -s /opt/v/v /usr/local/bin/v

WORKDIR /app
COPY . .
# Default GC (Boehm) — NOT -prealloc, NOT -gc none. V's -prealloc is a never-free bump
# arena: fine for short-lived programs (the compiler), but a long-running server grows
# unbounded under load (56GiB+ in the arena benchmark). -gc none would leak every
# per-request allocation. Boehm keeps memory bounded; c0624b2's codegen wins still apply.
RUN v -prod . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]
