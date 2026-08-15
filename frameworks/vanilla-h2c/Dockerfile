FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 5fb31f25 (0.5.2, built from source),
# the commit this entry was validated against. `make` bootstraps via the
# matching vc; if a much later rebuild ever fails to bootstrap, pin vlang/vc to
# the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout 5fb31f25bd9b056cc63cedc51b669073658b41a8 && \
    make && ln -s /opt/v/v /usr/local/bin/v

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
CMD ["/server"]
