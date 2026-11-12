# paozhu — HttpArena entry
#
# A build stage fetches the pinned upstream framework source and compiles the
# app, then a slim runtime stage whose CMD is the server. paozhu is not a
# linkable library: the application *is* a paozhu project, so its build graph
# comes from the pinned src/CMakeLists.txt — a snapshot of the upstream file
# with ENABLE_BENCHMARK=ON and the foreground main_docker.cpp entry baked in.

FROM debian:bookworm AS build

# Optional apt mirror for networks where deb.debian.org is slow; empty keeps
# the distro default, e.g. --build-arg APT_MIRROR=mirrors.aliyun.com
ARG APT_MIRROR=""
RUN if [ -n "$APT_MIRROR" ]; then \
        find /etc/apt -name '*.sources' -o -name 'sources.list' | \
            xargs -r sed -i "s|deb.debian.org/debian|${APT_MIRROR}/debian|g"; \
    fi

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        curl \
        ca-certificates \
        unzip \
        libssl-dev \
        zlib1g-dev \
        libbrotli-dev \
    && rm -rf /var/lib/apt/lists/*

# Pinned so mini_project.sh, the controller generator and the CMake entry point
# stay in sync with the scaffold this entry was written against.
ARG PAOZHU_REF=0f4e89ae1f72cb394119fa213da0ff3d109c3229
WORKDIR /paozhu
# Prefer a source archive shipped in the build context (offline / slow-GitHub
# environments); otherwise fetch the pinned revision from codeload. The direct
# codeload URL avoids github.com's /archive/ 302, which some networks block.
COPY . /ctx/
RUN if [ -f /ctx/vendor/paozhu-src.tar.gz ]; then \
        tar --strip-components=1 -xzf /ctx/vendor/paozhu-src.tar.gz; \
    else \
        curl -LSs "https://codeload.github.com/hggq/paozhu/tar.gz/${PAOZHU_REF}" | \
            tar --strip-components=1 -xz; \
    fi

# Upstream's clean-project initializer empties the ORM/view/demo layers and
# leaves only the framework core; paozhu_pre (run by CMake at build time)
# regenerates the router table from controller/src/*.cpp. The pinned copy in
# src/ carries one fix (still needed at 71305087): its Step 2 aborts under
# `set -e` when `grep -c` finds no RBAC markers in the stripped entry points.
COPY src/mini_project.sh /paozhu/mini_project.sh
RUN bash mini_project.sh && \
    rm -f controller/src/*.cpp && \
    unzip -q -o asio.zip

COPY src/controller/ /paozhu/controller/
COPY src/conf/ /paozhu/conf/

# A macOS-created build context can carry AppleDouble ._* sidecars. CMake globs
# every .cpp under controller/src, so ._arena.cpp would be compiled as C++.
RUN find /paozhu/controller /paozhu/conf -type f -name '._*' -delete && \
    find /paozhu/controller /paozhu/conf -type f -name '.DS_Store' -delete

# src/CMakeLists.txt already defaults ENABLE_BENCHMARK to ON and compiles
# startup/main_docker.cpp in every config, so no build-time patching is needed.
COPY src/CMakeLists.txt /paozhu/CMakeLists.txt
# The foreground entry itself is pinned too: it resolves argv[1] to a conf file
# and installs the SIGTERM handler that the two-conf-dir layout relies on.
COPY src/startup/main_docker.cpp /paozhu/startup/main_docker.cpp
RUN cmake -B build -S . \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_FLAGS="-O3 -march=native" && \
    cmake --build build -j"$(nproc)"

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3 \
        zlib1g \
        libbrotli1 \
        libstdc++6 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /paozhu/bin/paozhu /server
# httpserver::run() prefers <cwd>/conf/server.conf and only honours argv[1]
# when that file is absent. Two conf dirs (and no /app/conf/server.conf) make
# each process load its own file, hence its own ports.
COPY --from=build /paozhu/conf/server.conf    /app/conf/main/server.conf
COPY --from=build /paozhu/conf/server-h1.conf /app/conf/h1/server.conf
COPY --from=build /paozhu/conf/dh4096.pem     /app/conf/main/dh4096.pem
COPY --from=build /paozhu/conf/dh4096.pem     /app/conf/h1/dh4096.pem
COPY src/conf/openssl.cnf /app/conf/openssl.cnf
# Rendered by entrypoint.sh into /app/conf/main/orm.conf when the harness
# injects DATABASE_URL. Kept as .tpl so startup_orm_init() never sees it.
COPY src/conf/orm.conf /app/conf/orm.conf.tpl
COPY src/entrypoint.sh /entrypoint.sh

RUN mkdir -p /app/www/default /app/module/view /app/module/controller \
             /app/models /app/orm /app/view /app/temp /app/log /app/cache \
             /app/temp-h1 /app/log-h1 /app/plugins /app/libs && \
    printf 'Hello World! Paozhu\n' > /app/www/default/index.html && \
    chmod +x /entrypoint.sh

# Keeps the harness' RSA-2048 certificate while refusing TLS < 1.2 and the
# weak cipher families the TLS quality probe asks about.
ENV OPENSSL_CONF=/app/conf/openssl.cnf
EXPOSE 8080 8081 8082 8443
ENTRYPOINT ["/entrypoint.sh"]
