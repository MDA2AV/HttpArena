FROM ubuntu:26.04 AS cutelyst-build

ENV DEBIAN_FRONTEND=noninteractive

# Chunked request bodies + TCP-fragmented CRLF (HttpArena baseline / 8gbit).
ARG CUTELYST_REF=5ec5ce95d80a87b38ea45a326945bb22e515a23a

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
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git init cutelyst \
    && cd cutelyst \
    && git remote add origin https://github.com/cutelyst/cutelyst.git \
    && git fetch --depth 1 origin "${CUTELYST_REF}" \
    && git checkout FETCH_HEAD \
    && cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF \
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
    && rm -rf /var/lib/apt/lists/*

COPY --from=cutelyst-build /usr /usr

WORKDIR /app
COPY CMakeLists.txt main.cpp app.cpp app.h root.cpp root.h ./
RUN cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Install the released package for shared runtime deps, then overlay libs from CUTELYST_REF.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
    && wget -q https://github.com/cutelyst/cutelyst/releases/download/v5.1.0/cutelyst5-qt6_5.1.0_amd64.deb \
    && apt-get install -y --no-install-recommends ./cutelyst5-qt6_5.1.0_amd64.deb \
    && rm -f cutelyst5-qt6_5.1.0_amd64.deb \
    && rm -rf /var/lib/apt/lists/*

COPY --from=cutelyst-build /usr/lib/ /usr/lib/
COPY --from=app-build /app/build/server /server

EXPOSE 8080 8081
CMD ["/server"]
