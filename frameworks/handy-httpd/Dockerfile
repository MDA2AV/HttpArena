FROM ubuntu:24.04 AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl gcc xz-utils ca-certificates pkg-config \
        libsqlite3-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# Install LDC
ARG LDC_VERSION=1.42.0
RUN curl -fsSL "https://github.com/ldc-developers/ldc/releases/download/v${LDC_VERSION}/ldc2-${LDC_VERSION}-linux-x86_64.tar.xz" \
    | tar xJ -C /opt && \
    ln -s /opt/ldc2-${LDC_VERSION}-linux-x86_64 /opt/ldc
ENV PATH="/opt/ldc/bin:${PATH}"

WORKDIR /app
COPY dub.sdl .
COPY src ./src
RUN dub build -b release --compiler=ldc2

FROM ubuntu:24.04
RUN apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-0 zlib1g && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/httparena-handy-httpd /server
EXPOSE 8080
CMD ["/server"]
