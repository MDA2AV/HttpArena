# HttpArena entry for agensio (https://github.com/YiannisBourkelis/agensio): the tagged
# release built from source, the runtime on Debian slim like the nginx entry.
ARG AGENSIO_REF=v0.1.0-alpha.23

FROM debian:trixie AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git ca-certificates libssl-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
ARG AGENSIO_REF
WORKDIR /src
# asio is not on the system, so the build fetches the pinned standalone release itself.
RUN git clone --depth 1 --branch "${AGENSIO_REF}" https://github.com/YiannisBourkelis/agensio.git . \
    && cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DAGENSIO_TESTS=OFF -DAGENSIO_NATIVE=ON -DAGENSIO_HTTPARENA=ON \
    && cmake --build build --target agensio

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends libssl3t64 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/build/agensio /usr/local/bin/agensio
COPY agensio.toml start.sh /etc/agensio/
RUN chmod 0755 /etc/agensio/start.sh
EXPOSE 8080 8081 8082 8443 8443/udp
CMD ["/etc/agensio/start.sh"]
