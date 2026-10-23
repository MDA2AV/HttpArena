FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates cmake curl git gnupg libbrotli-dev libicu-dev liburing-dev \
        ninja-build zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/apt.llvm.org.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/apt.llvm.org.gpg] https://apt.llvm.org/noble/ llvm-toolchain-noble-23 main" \
        > /etc/apt/sources.list.d/apt.llvm.org.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        clang-23 libc++-23-dev libc++abi-23-dev lld-23 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --filter=blob:none \
        https://github.com/banderzhm/cnetmod.git /src/cnetmod \
    && git -C /src/cnetmod checkout 23b6dba3 \
    && git -C /src/cnetmod submodule update --init --depth 1 \
        3rdparty/boringssl 3rdparty/json 3rdparty/mimalloc \
        3rdparty/spdlog 3rdparty/stdexec

COPY CMakeLists.txt server.cpp /src/entry/
WORKDIR /src/entry

RUN cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang-23 \
        -DCMAKE_CXX_COMPILER=clang++-23 \
        -DSTDLIB_MODULE_DIRS=/usr/lib/llvm-23/share/libc++/v1 \
        -DSTDLIB_INCLUDE_DIRS=/usr/lib/llvm-23/include/c++/v1 \
        -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
    && cmake --build build \
        --target cnetmod-httparena cnetmod-httparena-h3 \
        --parallel "$(nproc)"

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libatomic1 libbrotli1 libicu74 liburing2 zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/lib/x86_64-linux-gnu/libc++.so.1* /usr/local/lib/
COPY --from=build /usr/lib/x86_64-linux-gnu/libc++abi.so.1* /usr/local/lib/
COPY --from=build /src/entry/build/cnetmod-httparena /server
COPY --from=build /src/entry/build/cnetmod-httparena-h3 /server-h3
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && ldconfig

EXPOSE 8080 8081 8082 8443/tcp 8443/udp
ENTRYPOINT ["/entrypoint.sh"]
