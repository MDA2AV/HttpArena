FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 5fb31f25 (0.5.2, built from source),
# the commit this entry was validated against.
#
# The bootstrap is pinned too. A bare `make` clones vlang/vc and vlang/tccbin at
# their CURRENT heads, so a fixed V source gets built by whatever compiler vc
# holds that day: that is what broke every V entry in #1288 ("C function C.open
# was already declared with a different signature"), and vc head has since
# failed in other ways. vc has no snapshot of 5fb31f25 itself; bd654de8 is the
# one generated from its parent (34520ac6, one commit behind). tccbin 696c1d84
# was tccbin's head when this V was cut, and `local=1` makes `make` build with
# both instead of pulling.
#
# Each repo is fetched at its one pinned commit (depth 1) rather than cloned:
# a full clone of v, vc and tccbin is hundreds of MB and a slow or flaky link
# stalls it past the validator's timeout; this is ~30 MB.
RUN git init -q /opt/v && cd /opt/v && \
    git fetch -q --depth 1 https://github.com/vlang/v 5fb31f25bd9b056cc63cedc51b669073658b41a8 && \
    git checkout -q FETCH_HEAD && \
    git init -q vc && \
    git -C vc fetch -q --depth 1 https://github.com/vlang/vc bd654de8a3e275178908fe824d29f58c70baaae5 && \
    git -C vc checkout -q FETCH_HEAD && \
    git init -q thirdparty/tcc && \
    git -C thirdparty/tcc fetch -q --depth 1 https://github.com/vlang/tccbin 696c1d84ad12e3a5b68b50fb0210819ed3d56bb8 && \
    git -C thirdparty/tcc checkout -q FETCH_HEAD && \
    make local=1 && ln -s /opt/v/v /usr/local/bin/v

# Install vanilla as the `vanilla` module (import vanilla.*), pinned to a
# specific commit: reproducible, with NO per-build network call to detect
# changes. To pick up upstream library fixes, bump this commit.
#
# Pinned to vanilla main @f1a9691 — the commit that carries the HTTP/2
# implementation (enghitalo/vanilla#122's http2 story) landed on top of the
# conn-mode seam (#136): a self-contained RFC 9113/7541 codec — HPACK (static +
# dynamic table, canonical Huffman, decoded-block ceiling), the frame codec,
# and the connection state machine with send-side flow control — serving
# cleartext h2c over the takeover seam, hardened against a live h2spec CI gate.
# This entry composes that machine with a small application handler; see main.v.
RUN git clone https://github.com/enghitalo/vanilla /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla checkout f1a96919587b6ba15a1dd9154cd1d75d10cb2a3e

WORKDIR /app
COPY . .
# json2 (import x.json2) is pure-V, so -prod is clean (the cJSON-backed `json`
# hard-errors under -prod on this V). -gc none: the serving path is
# allocation-free and the read-only dataset lives for the process lifetime.
RUN v -prod -gc none . -o server

FROM debian:stable-slim
# The binary links liburing.so.2 (the io_uring backend is compiled in on Linux
# even though this entry selects epoll at runtime).
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends liburing2 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

# h2c, prior-knowledge, on 8082 (HttpArena's cleartext HTTP/2 port).
EXPOSE 8082
# One worker per CPU the container may run on. vanilla defaults to nr_cpus,
# which reads the host's online CPUs (128 on the bench box) and ignores the
# cpuset, so a 64-CPU profile started 128 workers and latency-500k-8cpu would
# start 128 on 8. nproc honours the cpuset; an explicit VANILLA_WORKERS wins.
CMD ["/bin/sh", "-c", "VANILLA_WORKERS=${VANILLA_WORKERS:-$(nproc)} exec /server"]
