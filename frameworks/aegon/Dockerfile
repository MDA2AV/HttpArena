FROM archlinux:latest AS build

RUN pacman -Syu --noconfirm --needed \
    base-devel \
    cmake \
    ninja \
    git \
    liburing \
    glaze \
    openssl \
    libdeflate \
    sqlite \
    postgresql-libs

ARG AEGON_REPO=https://github.com/UdayKhare09/Aegon.git
ARG AEGON_REF=main
ARG AEGON_COMMIT=b1abba1

WORKDIR /src
RUN echo "Building Aegon commit: ${AEGON_COMMIT}" && \
    git clone --depth 1 --branch "${AEGON_REF}" "${AEGON_REPO}" aegon-src

WORKDIR /src/aegon-src
RUN cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build build --target aegon_core aegon_config aegon_redis aegon_memory aegon_http aegon_gateway aegon_cli -j$(nproc) && \
    cmake --install build

WORKDIR /app
COPY CMakeLists.txt main.cpp ./
RUN cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -j$(nproc)

FROM archlinux:latest

RUN pacman -Syu --noconfirm --needed \
    liburing \
    openssl \
    libdeflate \
    sqlite \
    postgresql-libs \
    jemalloc && \
    pacman -Scc --noconfirm

ENV LD_PRELOAD=/usr/lib/libjemalloc.so
ENV LD_LIBRARY_PATH=/usr/local/lib

COPY --from=build /usr/local/lib/ /usr/local/lib/
COPY --from=build /app/build/aegon-arena /usr/local/bin/aegon-arena

EXPOSE 8080 8081 8082 8443 8443/udp

CMD ["/usr/local/bin/aegon-arena"]
