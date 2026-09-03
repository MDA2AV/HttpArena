# Shared image for both HttpArena Proxygen entries.
#
#   TARGET=classic -> proxygen::HTTPServer + mvfst HQServer   (`proxygen`)
#   TARGET=coro    -> proxygen::coro::HTTPServer              (`proxygen-coro`)
#
# `frameworks/proxygen-coro/build.sh` builds this same context with
# `--build-arg TARGET=coro`, so every fix to src/ lands in both entries at once.
#
# PROXYGEN_BASE is pinned by digest so a benchmark round is reproducible; bump
# it deliberately rather than tracking a moving `:latest`.
ARG PROXYGEN_BASE=ghcr.io/facebook/proxygen/base@sha256:3f9c745ea7a3e065bdf6887f7255f2547c17c67fc1210ff120e9e52daa8eb3dc
ARG MIMALLOC_TAG=v2.1.7

# glibc malloc is the bottleneck on the allocation-heavy profiles: the JSON
# routes build a live folly::dynamic per request (up to 50 item copies plus the
# serialized string), and proxygen's coroutine server allocates a frame per
# event. Measured on this workload, mimalloc is worth +35% on `json` and
# +39%/+88% (classic/coro) on `json-comp`, against roughly -5% on `static`,
# where the large per-file IOBuf hits mimalloc's large-object path.
FROM ${PROXYGEN_BASE} AS mimalloc
ARG MIMALLOC_TAG
RUN git clone --depth 1 -b "${MIMALLOC_TAG}" https://github.com/microsoft/mimalloc.git /src/mimalloc \
    && cmake -S /src/mimalloc -B /src/build -DCMAKE_BUILD_TYPE=Release -DMI_BUILD_TESTS=OFF \
    && cmake --build /src/build --parallel "$(nproc)" \
    && cp "$(readlink -f /src/build/libmimalloc.so)" /src/libmimalloc.so

FROM ${PROXYGEN_BASE} AS build
ARG TARGET=classic

WORKDIR /arena
COPY CMakeLists.txt ./
COPY src ./src
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DSERVER_TARGET="${TARGET}" \
    && cmake --build build --parallel "$(nproc)" \
    && strip build/arena-server

# Follow Proxygen's quic-interop image pattern: preserve the resolved shared
# library paths, then copy only those libraries and the server binary to
# a same-distro runtime image.
RUN set -eux; \
    ldd build/arena-server \
      | awk '/=> \// { print $3 } /^\// { print $1 }' | sort -u > /tmp/runtime-libs.txt; \
    tar -chf /tmp/runtime-libs.tar --files-from=/tmp/runtime-libs.txt

FROM ubuntu:24.04@sha256:019e8eb29a85e74d64925745884f2ec79aa27e3feab36353d24656f4d6b89467

ENV LD_LIBRARY_PATH=/opt/proxygen/lib \
    LD_PRELOAD=/usr/local/lib/libmimalloc.so \
    MIMALLOC_PURGE_DELAY=1

COPY --from=build /tmp/runtime-libs.tar /tmp/runtime-libs.tar
RUN tar -xf /tmp/runtime-libs.tar -C / \
    && rm /tmp/runtime-libs.tar

COPY --from=mimalloc /src/libmimalloc.so /usr/local/lib/libmimalloc.so
COPY --from=build /arena/build/arena-server /usr/local/bin/arena-server
COPY entrypoint.sh /usr/local/bin/arena-entrypoint
RUN chmod +x /usr/local/bin/arena-entrypoint \
    && groupadd --system --gid 10001 httparena \
    && useradd --system --uid 10001 --gid httparena --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin httparena

EXPOSE 8080/tcp 8081/tcp 8082/tcp 8443/tcp 8443/udp

USER httparena
ENTRYPOINT ["/usr/local/bin/arena-entrypoint"]
