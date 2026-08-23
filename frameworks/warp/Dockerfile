FROM debian:trixie-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        ghc \
        libghc-warp-dev \
        libghc-warp-tls-dev \
        libghc-directory-dev \
        libghc-wai-dev \
        libghc-wai-extra-dev \
        libghc-http-types-dev \
        libghc-aeson-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Main.hs .
RUN ghc -O2 -threaded -rtsopts -with-rtsopts=-N -o server Main.hs

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgmp10 libffi8 libnuma1 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
