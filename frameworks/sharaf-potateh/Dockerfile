FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates clang curl gzip libgc-dev libunwind-dev openjdk-21-jdk && \
    rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://github.com/VirtusLab/scala-cli/releases/download/v1.16.0/scala-cli-x86_64-pc-linux.gz | gzip -d > /usr/local/bin/scala-cli && \
    chmod +x /usr/local/bin/scala-cli
WORKDIR /app
COPY Main.scala .
RUN scala-cli --power package Main.scala --native --native-mode release-fast --server=false -o /app/server

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libgc1 libunwind8 && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
