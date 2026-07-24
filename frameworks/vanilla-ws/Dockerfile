FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 5fb31f25 (built from source), the
# commit this entry was validated against. `make` bootstraps via the matching
# vc; if a much later rebuild ever fails to bootstrap, pin vlang/vc to the
# commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout 5fb31f25bd9b056cc63cedc51b669073658b41a8 && \
    make && ln -s /opt/v/v /usr/local/bin/v

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
CMD ["/server"]
