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
    postgresql-libs \
    protobuf

ARG AEGON_REPO=https://github.com/UdayKhare09/Aegon.git
ARG AEGON_REF=main
ARG AEGON_COMMIT=ec6afdb

WORKDIR /src
RUN echo "Building Aegon commit: ${AEGON_COMMIT}" && \
    git clone --branch "${AEGON_REF}" "${AEGON_REPO}" aegon-src && \
    cd aegon-src && \
    git checkout "${AEGON_COMMIT}"

WORKDIR /src/aegon-src
RUN cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DAEGON_BUILD_TESTS=OFF \
    -DAEGON_BUILD_SAMPLES=OFF \
    -DAEGON_BUILD_BENCHMARKS=OFF \
    -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build build -j$(nproc) && \
    cmake --install build

WORKDIR /app
COPY CMakeLists.txt main.cpp ./
COPY proto/ ./proto/
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
    jemalloc \
    protobuf && \
    pacman -Scc --noconfirm

ENV LD_PRELOAD=/usr/lib/libjemalloc.so
ENV LD_LIBRARY_PATH=/usr/local/lib

COPY --from=build /usr/local/lib/ /usr/local/lib/
COPY --from=build /app/build/aegon-arena /usr/local/bin/aegon-arena

EXPOSE 8080 8081 8082 8443 8443/udp

CMD ["/usr/local/bin/aegon-arena"]
