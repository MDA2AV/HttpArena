FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libpq-dev liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V 0.5.1, built from source. Plain `make` can't build an old
# tag — its `latest_vc` step `git pull`s the newest vlang/vc bootstrap, which no
# longer matches 0.5.1's vlib ("unknown ident `native`"). So pin the vc bootstrap
# to the commit cut for 0.5.1 (vlang/vc f461dfeb = "[v:master] 0c3183c - V 0.5.1")
# and run make's own bootstrap recipe (cc -> v1 -> v2 -> v). Pinned by tag, not a
# master commit, because post-0.5.1 master has a codegen regression (single-element
# array push 4-7x slower, vlang/v#27468).
RUN git clone --branch 0.5.1 --depth 1 https://github.com/vlang/v /opt/v && \
    git clone --filter=blob:none --quiet https://github.com/vlang/vc /opt/v/vc && \
    git -C /opt/v/vc checkout -q f461dfebcdfa && \
    git clone --filter=blob:none --quiet --branch thirdparty-linux-amd64 \
        https://github.com/vlang/tccbin /opt/v/thirdparty/tcc && \
    cd /opt/v && \
    cc -std=c99 -w -o v1 vc/v.c -lm -lpthread && \
    ./v1 -no-parallel -o v2 cmd/v && \
    ./v2 -nocache -o v cmd/v && \
    rm -f v1 v2 && \
    ln -s /opt/v/v /usr/local/bin/v

# Install the vanilla HTTP server as the `vanilla` module (import vanilla.http_server).
# The ADD fetches vanilla's main ref first, so Docker invalidates this layer's
# cache whenever main moves — otherwise the clone layer is cached indefinitely and
# the build never picks up upstream library fixes.
ADD https://api.github.com/repos/enghitalo/vanilla/git/refs/heads/main /tmp/vanilla-main-ref.json
RUN git clone --depth 1 https://github.com/enghitalo/vanilla /root/.vmodules/vanilla

WORKDIR /app
COPY . .
RUN v -prod . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 liburing2 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]
