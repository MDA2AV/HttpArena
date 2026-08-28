FROM debian:trixie-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates pkg-config \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Pinned by commit so a build here is reproducible rather than tracking master.
ARG LWAN_REF=master
WORKDIR /src
RUN git clone --branch "${LWAN_REF}" https://github.com/lpereira/lwan.git . \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    && cmake --build build -j"$(nproc)" --target lwan-static

WORKDIR /app
COPY src/main.c ./
# --whole-archive is required: lwan registers its modules and handlers into
# custom linker sections, and the __start_/__stop_ boundary symbols only exist
# if something contributes to them. Archive members are pulled in on reference
# alone, so without this the section stays empty and the link fails on
# undefined __start_lwan_module.
RUN gcc -O3 -std=gnu11 -I/src/src/lib -I/src/build \
        main.c \
        -o server \
        -Wl,--whole-archive /src/build/src/lib/liblwan.a -Wl,--no-whole-archive \
        -lpthread -lz -lm -ldl

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
COPY entrypoint.sh /entrypoint.sh
WORKDIR /app
EXPOSE 8080
CMD ["/entrypoint.sh"]
