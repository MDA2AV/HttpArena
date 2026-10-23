# Plod's HttpArena entry: app.goose, served by the root files server.goose
# and server_tls.goose, which declare Plod and its packages at their tags;
# Goose fetches them from GitHub as it builds.
FROM ubuntu:26.04 AS build
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends ca-certificates curl git cmake ninja-build gcc g++ \
        liburing-dev libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Goose's release, checked against its SHA-256. The release has no archive
# for Linux on arm64, so there its tag is built from source.
ARG GOOSE_RELEASE=v2026.3
ARG GOOSE_SHA256=06ac30284338269d3996d457412bf4f2b47c1f9a5601de65b6317187fe78d5c9
RUN set -eu; \
    case "$(uname -m)" in \
    x86_64) \
        curl -fsSL -o /tmp/goose.tar.gz \
            "https://github.com/aardappel/goose/releases/download/$GOOSE_RELEASE/goose-$GOOSE_RELEASE-linux-x64.tar.gz"; \
        echo "$GOOSE_SHA256  /tmp/goose.tar.gz" | sha256sum -c -; \
        tar -xzf /tmp/goose.tar.gz -C /opt; \
        rm /tmp/goose.tar.gz; \
        echo "/opt/goose-$GOOSE_RELEASE-linux-x64/goose" >/goose-path ;; \
    *) \
        git clone -q --depth 1 --branch "$GOOSE_RELEASE" https://github.com/aardappel/goose.git /opt/goose; \
        cmake -S /opt/goose -B /opt/goose/build -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null; \
        cmake --build /opt/goose/build >/dev/null; \
        echo /opt/goose/build/goose >/goose-path ;; \
    esac

WORKDIR /src
COPY app.goose server.goose server_tls.goose ./
# Two builds: server, without TLS, and server-tls, with the TLS listeners:
# goose-tls's TLS 1.3 server, in Goose, over OpenSSL's libcrypto for the
# ciphers and keys. The plain profiles don't load libcrypto.
# goose build takes no C flags, so gcc comes through a wrapper that adds
# -O3 and -march=native after Goose's -O2; HttpArena builds the image on the
# machine it runs on.
RUN mkdir /opt/cc && printf '#!/bin/sh\nexec /usr/bin/gcc "$@" -O3 -march=native\n' >/opt/cc/gcc && \
    chmod +x /opt/cc/gcc && \
    goose=$(cat /goose-path) && \
    $goose build --cc /opt/cc/gcc --standalone -o /server server.goose && \
    $goose build --cc /opt/cc/gcc --standalone -o /server-tls server_tls.goose

FROM ubuntu:26.04
# goose-http links liburing on Linux, and the TLS build OpenSSL.
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends liburing2 libssl3t64 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /server /server
COPY --from=build /server-tls /server-tls
EXPOSE 8080 8081 8082 8443
# The TLS build where HttpArena mounts the certificate at /certs, for the
# profiles that use it; the other otherwise. One worker per CPU of the
# container's cpuset, goose-http's default.
CMD ["/bin/sh", "-c", "if [ -r /certs/server.crt ] && [ -r /certs/server.key ]; then TLS_CERT=/certs/server.crt TLS_KEY=/certs/server.key exec /server-tls; fi; exec /server"]
