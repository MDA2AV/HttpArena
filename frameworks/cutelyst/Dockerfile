FROM ubuntu:26.04 AS cutelyst-build

ENV DEBIAN_FRONTEND=noninteractive

# Chunked request bodies + TCP-fragmented CRLF (HttpArena baseline / 8gbit).
ARG CUTELYST_REF=5ec5ce95d80a87b38ea45a326945bb22e515a23a
# ASql 1.x (async Postgres). Pin when tagging a release.
ARG ASQL_REF=eebafdde3069008626a558b15ae641ab356c799b
ARG CUTELEE_REF=v6.2.0

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        g++ \
        git \
        ninja-build \
        pkg-config \
        qt6-base-dev \
        qt6-tools-dev \
        qt6-l10n-tools \
        qt6-declarative-dev \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Django-style templates for fortunes (not in Ubuntu archives).
RUN git init cutelee \
    && cd cutelee \
    && git remote add origin https://github.com/cutelyst/cutelee.git \
    && git fetch --depth 1 origin "${CUTELEE_REF}" \
    && git checkout FETCH_HEAD \
    && cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DBUILD_TEMPLATES=ON \
        -DBUILD_TEXTDOCUMENT=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_DOCS=OFF \
    && cmake --build build \
    && cmake --install build

# Async Postgres driver for async-db / fortunes.
RUN git init asql \
    && cd asql \
    && git remote add origin https://github.com/cutelyst/asql.git \
    && git fetch --depth 1 origin "${ASQL_REF}" \
    && git checkout FETCH_HEAD \
    && cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DASQL_DRIVER_POSTGRES=ON \
        -DASQL_DRIVER_MYSQL=OFF \
        -DASQL_DRIVER_ODBC=OFF \
        -DASQL_DRIVER_SQLITE=OFF \
        -DASQL_BUILD_DEMOS=OFF \
        -DASQL_MIGRATION_TOOL=OFF \
        -DBUILD_TESTING=OFF \
    && cmake --build build \
    && cmake --install build

RUN git init cutelyst \
    && cd cutelyst \
    && git remote add origin https://github.com/cutelyst/cutelyst.git \
    && git fetch --depth 1 origin "${CUTELYST_REF}" \
    && git checkout FETCH_HEAD \
    && cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF \
        -DPLUGIN_VIEW_CUTELEE=ON \
    && cmake --build build \
    && cmake --install build

FROM ubuntu:26.04 AS app-build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        g++ \
        ninja-build \
        pkg-config \
        qt6-base-dev \
        qt6-declarative-dev \
        libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=cutelyst-build /usr /usr

WORKDIR /app
COPY CMakeLists.txt main.cpp app.cpp app.h root.cpp root.h fortunes.html ./
RUN cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build \
    && mkdir -p /app/templates \
    && cp fortunes.html /app/templates/fortunes.html

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Install the released package for shared runtime deps, then overlay libs from CUTELYST_REF.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        libpq5 \
        libqt6qml6 \
    && wget -q https://github.com/cutelyst/cutelyst/releases/download/v5.1.0/cutelyst5-qt6_5.1.0_amd64.deb \
    && apt-get install -y --no-install-recommends ./cutelyst5-qt6_5.1.0_amd64.deb \
    && rm -f cutelyst5-qt6_5.1.0_amd64.deb \
    && rm -rf /var/lib/apt/lists/*

COPY --from=cutelyst-build /usr/lib/ /usr/lib/
COPY --from=app-build /app/build/server /server
COPY --from=app-build /app/templates /templates

ENV CUTELEE_INCLUDE_PATH=/templates
ENV LANG=C.UTF-8

EXPOSE 8080 8081
CMD ["/server"]
