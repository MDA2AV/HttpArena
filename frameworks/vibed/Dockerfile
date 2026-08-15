FROM debian:trixie-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates dub gcc ldc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY dub.json dub.selections.json ./
COPY source ./source
RUN dub build --build=release --compiler=ldc2

FROM debian:trixie-slim
COPY --from=build /src/server /usr/local/bin/server
EXPOSE 8080
CMD ["/usr/local/bin/server"]
