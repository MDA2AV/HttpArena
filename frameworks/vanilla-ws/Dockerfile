FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 5fb31f25 (built from source), the
# commit this entry was validated against.
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

# Install vanilla as the `vanilla` module (import vanilla.server), pinned to a
# specific commit: reproducible, with NO per-build network call to detect
# changes. To pick up upstream library fixes, bump this commit.
#
# Pinned to vanilla main @ab0791b — carries the conn-mode seam
# (enghitalo/vanilla#136): a protocol-neutral connection-takeover contract in
# core (queue_takeover + ConnHandler) that lets an HTTP handler flip the
# connection out of the HTTP/1.1 state machine after the 101, plus the
# websocket module — a pure RFC 6455 codec (accept-key, frame-head parsing
# with the full malformed matrix, in-place unmasking, unmasked server-frame
# writers). This entry composes the two; see main.v.
RUN git clone https://github.com/enghitalo/vanilla /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla checkout ab0791b54717db843be3ed820c97ad93398930ff

WORKDIR /app
COPY . .
RUN v -prod -gc none . -o server

FROM debian:stable-slim
# The binary links liburing.so.2 (the io_uring backend is compiled in on
# Linux even though this entry selects epoll at runtime).
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends liburing2 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
# One worker per CPU the container may run on. vanilla defaults to nr_cpus,
# which reads the host's online CPUs (128 on the bench box) and ignores the
# cpuset, so a 64-CPU profile started 128 workers and latency-500k-8cpu would
# start 128 on 8. nproc honours the cpuset; an explicit VANILLA_WORKERS wins.
CMD ["/bin/sh", "-c", "VANILLA_WORKERS=${VANILLA_WORKERS:-$(nproc)} exec /server"]
