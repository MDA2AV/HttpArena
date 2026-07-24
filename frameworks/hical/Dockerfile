# HttpArena — Hical C++20/26 Web Framework
# 多阶段 Docker 构建
#
# 第一阶段：编译 Hical 框架 + HttpArena benchmark 服务器
# 第二阶段：精简运行镜像

# --- 构建阶段 ---
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates gcc-14 g++-14 cmake ninja-build git \
        libboost-all-dev libssl-dev libgtest-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone Hical 项目源码（包含 HttpArena benchmark 文件在 docker/HttpArena/ 下）
ARG HICAL_REPO=https://github.com/Hical61/Hical.git
ARG HICAL_REF=main

WORKDIR /src
RUN git clone --depth 1 --branch ${HICAL_REF} ${HICAL_REPO} .

RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=gcc-14 \
        -DCMAKE_CXX_COMPILER=g++-14 \
        -DCMAKE_CXX_FLAGS="-march=native -mtune=native" \
        -DHICAL_BUILD_HTTPARENA=ON \
        -DHICAL_BUILD_TESTS=OFF \
        -DHICAL_BUILD_EXAMPLES=OFF \
    && cmake --build build --target httparena_server -j$(nproc) \
    && strip build/httparena_server

# --- 运行阶段（最小镜像） ---
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        libboost-json1.83.0 libssl3t64 zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/build/httparena_server /server

EXPOSE 8080

CMD ["/server"]
