FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates git build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit cd213a17c (built from source). No release
# tag carries the modern stdlib this framework needs: the pooled Go-style `db.pg`
# (vlang/v#27265). cd213a17c also carries the Boehm GC free-space-divisor fix
# (vlang/v#27560, fixes vlang/v#27555) that recovers the default-GC throughput
# regression seen in the c0624b2..6c4d26f range. `make` bootstraps via the matching
# vc; if a much later rebuild ever fails to bootstrap, pin vlang/vc to the commit
# cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout cd213a17c && \
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
