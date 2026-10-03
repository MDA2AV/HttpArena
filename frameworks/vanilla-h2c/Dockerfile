FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit b99970bd (0.5.2, built from source),
# the commit this entry was validated against.
#
# The bootstrap is pinned too. A bare `make` clones vlang/vc and vlang/tccbin at
# their CURRENT heads, so a fixed V source gets built by whatever compiler vc
# holds that day: that is what broke every V entry in #1288 ("C function C.open
# was already declared with a different signature"), and vc head has since
# failed in other ways. vc 2cbaf6bc is vc's newest snapshot (generated from V
# 0c41fadb, 40 commits earlier; vc has none for b99970bd yet), so it is what
# `make` bootstraps this V with today; tccbin d6e7ac1b is the head of tccbin's
# thirdparty-linux-amd64 branch, and `local=1` makes `make` build with both
# instead of pulling.
#
# Each repo is fetched at its one pinned commit (depth 1) rather than cloned:
# a full clone of v, vc and tccbin is hundreds of MB and a slow or flaky link
# stalls it past the validator's timeout; this is ~30 MB.
RUN git init -q /opt/v && cd /opt/v && \
    git fetch -q --depth 1 https://github.com/vlang/v b99970bd438a7bdcdfbe38f74d9364db801d5439 && \
    git checkout -q FETCH_HEAD && \
    git init -q vc && \
    git -C vc fetch -q --depth 1 https://github.com/vlang/vc 2cbaf6bc2367937cd5f0b4ef923d1ef9aad613b3 && \
    git -C vc checkout -q FETCH_HEAD && \
    git init -q thirdparty/tcc && \
    git -C thirdparty/tcc fetch -q --depth 1 https://github.com/vlang/tccbin d6e7ac1b1bcc98aed734a6ecbfa8509f24606c74 && \
    git -C thirdparty/tcc checkout -q FETCH_HEAD && \
    make local=1 && ln -s /opt/v/v /usr/local/bin/v

# Install vanilla as the `vanilla` module (import vanilla.*), pinned to a
# specific commit: reproducible, with NO per-build network call to detect
# changes. To pick up upstream library fixes, bump this commit.
#
# Pinned to vanilla main @091c014. It has response trailers
# (enghitalo/vanilla#174), which unary-grpc needs to send grpc-status after
# the message, and no allocation per request in http2 (#175): HPACK literals
# decoded into a per-connection arena and copied into the stream's pooled
# storage, and a fixed stream table instead of a map. Under -gc none the
# old path kept ~200 B per request (10 GiB in a 5 s run); RSS is now flat
# per request. Fetched at that one commit.
RUN git init -q /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla fetch -q --depth 1 https://github.com/enghitalo/vanilla \
        091c014a0191afd7e740b84f5599b9b1fc1fd914 && \
    git -C /root/.vmodules/vanilla checkout -q FETCH_HEAD

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

# h2c, prior-knowledge, on 8082 (HttpArena's cleartext HTTP/2 port) and on
# 8080, where the harness drives unary gRPC.
EXPOSE 8080 8082
# One worker per CPU the container may run on. vanilla defaults to nr_cpus,
# which reads the host's online CPUs (128 on the bench box) and ignores the
# cpuset, so a 64-CPU profile started 128 workers and latency-500k-8cpu would
# start 128 on 8. nproc honours the cpuset; an explicit VANILLA_WORKERS wins.
CMD ["/bin/sh", "-c", "VANILLA_WORKERS=${VANILLA_WORKERS:-$(nproc)} exec /server"]
