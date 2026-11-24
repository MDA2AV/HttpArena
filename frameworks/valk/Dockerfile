FROM ubuntu:24.04 AS build

ARG VALK_VERSION=0.8.8
ARG VALK_SHA256_X64=b371b3b85f8d552e6fb7df1fd9768efa837097b2bb7da501fee7ae3c75b75de8
ARG VALK_SHA256_ARM64=fa7e5c33458c434222efa691ae519e08906dec8ce0b5a961c02c018acdb4f755

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
RUN valk build src -o /server --release --static

FROM ubuntu:24.04
COPY --from=build /server /server
EXPOSE 8080 8081 8082 8443
CMD ["/server"]
