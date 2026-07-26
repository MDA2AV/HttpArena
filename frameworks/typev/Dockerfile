FROM ubuntu:24.04

# wget + unzip fetch the typev runtime at build time; libatomic1 + ca-certificates
# are runtime deps (typev needs libatomic for its 128-bit atomics, ca-certificates
# lets wget verify the object-storage TLS cert). typev statically links liburing,
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget unzip libatomic1 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# typev VM — binary + FFI plugins (json, stdcore, stdsocket, ...). Pre-built
# (-O3 -march=x86-64-v3, static liburing) and fetched from object storage
RUN wget -q -O /tmp/typev.zip \
        https://typev.s3.fr-par.scw.cloud/typev-23-05-2026-v2.zip && \
    unzip -q /tmp/typev.zip -d /app && \
    rm /tmp/typev.zip

# Compiled benchmark server — kept in the repo, version-matched to the
# source in benchmark-code/src/main.tc. The S3 zip ships the VM only.
COPY bundle/output.tvbc /app/output.tvbc

# Fixes number of threads to 64, ignoring sysconf(NPROCESSORS)
ENV TV_WORKERS=64

EXPOSE 8080
CMD ["/app/typev", "/app/output.tvbc"]
