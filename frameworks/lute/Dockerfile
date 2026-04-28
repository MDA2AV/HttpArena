ARG LUTE_VERSION=1.0.1-nightly.20260421

FROM buildpack-deps:curl AS bin

RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*

ARG LUTE_VERSION
ARG TARGETARCH

RUN ARCH=$(echo "${TARGETARCH:-amd64}" | sed -e 's/arm64/aarch64/' -e 's/amd64/x86_64/') \
    && curl -fsSL "https://github.com/luau-lang/lute/releases/download/v${LUTE_VERSION}/lute-linux-${ARCH}.zip" --output lute.zip \
    && unzip lute.zip \
    && chmod +x lute

FROM debian:stable-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=bin /lute /usr/local/bin/lute

WORKDIR /usr/src/app

COPY server.luau serve.luau ./

ENV LUTE_UNBUFFERED=1

EXPOSE 8080 8081

ENTRYPOINT ["lute", "server.luau"]
