FROM ocaml/opam:debian-12-ocaml-5.4 AS build

ARG HCS_VERSION=0.18.0
ARG SIMDJSONT_VERSION=0.5.0
ARG REPODB_VERSION=0.9.0
ARG OPAM_JOBS=4

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      git libpq-dev libgmp-dev zlib1g-dev libzstd-dev libssl-dev pkg-config m4 cmake \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app && chown opam:opam /app
USER opam
WORKDIR /app

# Install the released library, not an unpublished checkout. Refresh both
# indexes so the base image's cached opam repository cannot hide new releases.
RUN opam repo add araara git+https://tangled.org/gdiazlo.tngl.sh/repo \
 && opam update \
 && opam install -y --jobs=${OPAM_JOBS} "hcs.${HCS_VERSION}" "repodb.${REPODB_VERSION}" "repodb-postgresql.${REPODB_VERSION}" "simdjsont.${SIMDJSONT_VERSION}"

# The benchmark application is part of the submission, independent of the
# library release. HttpArena can review and update its endpoints here.
COPY --chown=opam:opam dune-project ./
COPY --chown=opam:opam server ./server
RUN opam exec -- dune build --profile release server/arena.exe

RUN mkdir -p /app/staging/lib \
 && cp -L _build/default/server/arena.exe /app/staging/server \
 && ldd _build/default/server/arena.exe \
      | awk '/=> \//{print $3}' | sort -u \
      | grep -vE '/(libc|libm|libpthread|libdl|librt|ld-linux)[.-]' \
      | while read -r lib; do cp -Lv "$lib" /app/staging/lib/; done

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/staging/lib/ /usr/local/lib/
COPY --from=build /app/staging/server /usr/local/bin/server
RUN ldconfig

# Eio prefers io_uring and falls back to POSIX when the host denies it.
# Forcing EIO_BACKEND=io-uring disables that fallback in Eio 1.6.
ENV HCS_H2_MAX_STREAMS=64

EXPOSE 8080 8443 8081 8082
CMD ["/usr/local/bin/server"]
