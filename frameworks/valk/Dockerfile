FROM ubuntu:24.04 AS build

ARG VALK_VERSION=0.10.0
ARG VALK_SHA256_X64=160ab7fe9439ae207f5f611760d298147c392d86020511f44ec88adf9999df35
ARG VALK_SHA256_ARM64=7a4bc0aeb00566ab649688ff30367951ea9816ab0c00107ea0f4aa83d9ed7a47

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64) target="linux-x64"; sha256="$VALK_SHA256_X64" ;; \
        aarch64) target="linux-arm64"; sha256="$VALK_SHA256_ARM64" ;; \
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/valk; \
    curl -fsSL -o /tmp/valk.tar.gz "https://files.valk-cdn.dev/releases/valk/${VALK_VERSION}/valk-${VALK_VERSION}-${target}.tar.gz"; \
    echo "${sha256}  /tmp/valk.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/valk.tar.gz -C /opt/valk; \
    rm -f /tmp/valk.tar.gz

ENV PATH="/opt/valk:${PATH}"

WORKDIR /app
COPY valk.json ./
COPY src ./src
RUN set -eux; \
    for spec in \
        "valk-grpc 0.1.3" \
        "valk-postgres 0.9.2" \
        "valk-protobuf 0.2.1" \
        "valk-sql 0.5.0"; do \
        set -- $spec; repo="$1"; ver="$2"; \
        mkdir -p "vendor/github-ctxcode-${repo}/${ver}"; \
        curl -fsSL "https://github.com/ctxcode/${repo}/archive/refs/tags/${ver}.tar.gz" \
            | tar -xz --strip-components=1 -C "vendor/github-ctxcode-${repo}/${ver}"; \
    done; \
    mkdir -p vendor/github-ctxcode-valk-postgres/0.9.2/vendor; \
    ln -s /app/vendor/github-ctxcode-valk-sql vendor/github-ctxcode-valk-postgres/0.9.2/vendor/github-ctxcode-valk-sql
RUN valk build src -o /server --release --static

FROM ubuntu:24.04
COPY --from=build /server /server
EXPOSE 8080 8081 8082 8443
CMD ["/server"]
