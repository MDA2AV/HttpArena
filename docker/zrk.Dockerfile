# zrk — constant-throughput HTTP load generator (Zig, io_uring).
#
# A rewrite of wrk2 with nanosecond pacing instead of wrk2's millisecond timer
# wheel, coordinated-omission correction, and a JSON summary. Used by the
# `millionaire` profile, which holds the offered rate fixed and measures what
# the server spends to serve it.
#
# Version-pinned with a checksum rather than tracking a branch the way gcannon
# does. The premise of that profile is that the offered load is byte-identical
# across entries and across rounds, so a generator that drifts under it
# invalidates every comparison it was measured against, including old ones.
# Bumping the version is a deliberate act that re-baselines the profile.
FROM ubuntu:24.04 AS build
ARG ZRK_VERSION=2.3.0
# One checksum per release asset; the build picks the one for the host's
# architecture so the same Dockerfile works on x86_64 and aarch64 hosts.
ARG ZRK_SHA256_X86_64=ab6f1c1ce34ce73f52afd106419d15e5c494bd1cedd475afa56babb85b09a816
ARG ZRK_SHA256_AARCH64=361f2632e3cee672cf6a8676438c9fa93e8a5702a0007bacc266861767bab213
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN arch="$(uname -m)" && \
    case "$arch" in \
        x86_64)  sum="$ZRK_SHA256_X86_64" ;; \
        aarch64) sum="$ZRK_SHA256_AARCH64" ;; \
        *) echo "zrk: no release for $arch" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o zrk.tar.gz \
        "https://github.com/zoxy-io/zrk/releases/download/v${ZRK_VERSION}/zrk-${ZRK_VERSION}-${arch}-linux.tar.gz" && \
    echo "${sum}  zrk.tar.gz" | sha256sum -c - && \
    tar xzf zrk.tar.gz && chmod +x zrk

FROM ubuntu:24.04
# zrk links statically, so nothing but the binary is needed at runtime.
COPY --from=build /build/zrk /usr/local/bin/zrk
ENTRYPOINT ["zrk"]
