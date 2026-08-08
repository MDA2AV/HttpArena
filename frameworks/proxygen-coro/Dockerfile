FROM ghcr.io/facebook/proxygen/base:latest AS build

WORKDIR /arena
COPY CMakeLists.txt ArenaCoroServer.cpp ./
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --parallel "$(nproc)" \
    && strip build/proxygen-arena-coro

RUN set -eux; \
    ldd build/proxygen-arena-coro \
      | awk '/=> \// { print $3 } /^\// { print $1 }' | sort -u > /tmp/runtime-libs.txt; \
    tar -chf /tmp/runtime-libs.tar --files-from=/tmp/runtime-libs.txt

FROM ubuntu:24.04@sha256:019e8eb29a85e74d64925745884f2ec79aa27e3feab36353d24656f4d6b89467

ENV LD_LIBRARY_PATH=/opt/proxygen/lib

COPY --from=build /tmp/runtime-libs.tar /tmp/runtime-libs.tar
RUN tar -xf /tmp/runtime-libs.tar -C / \
    && rm /tmp/runtime-libs.tar

COPY --from=build /arena/build/proxygen-arena-coro /usr/local/bin/proxygen-arena-coro
COPY entrypoint.sh /usr/local/bin/proxygen-coro-entrypoint
RUN chmod +x /usr/local/bin/proxygen-coro-entrypoint \
    && groupadd --system --gid 10001 httparena \
    && useradd --system --uid 10001 --gid httparena --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin httparena

EXPOSE 8080/tcp 8081/tcp 8082/tcp 8443/tcp 8443/udp

USER httparena
ENTRYPOINT ["/usr/local/bin/proxygen-coro-entrypoint"]
