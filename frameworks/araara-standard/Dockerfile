# HttpArena standard-mode submission image for araara.
#
# This package builds the same benchmark server as the tuned araara entry, but
# sets HCS_ARENA_MODE=standard so arena/server/arena.ml keeps Hcs.Server defaults
# where the harness does not require protocol, port, TLS, or upload size fields.

FROM ocaml/opam:debian-12-ocaml-5.4 AS build

ARG HCS_VERSION=0.16.1

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      git libpq-dev libgmp-dev zlib1g-dev libzstd-dev libssl-dev pkg-config m4 cmake \
    && rm -rf /var/lib/apt/lists/*
USER opam
WORKDIR /app

# Provides hcs, http-proto, repodb, and repodb-postgresql. Public-readable git.
RUN opam repo add araara git+https://tangled.org/gdiazlo.tngl.sh/repo && opam update

RUN opam source --dir hcs "hcs.${HCS_VERSION}"
COPY standard-mode.patch /app/standard-mode.patch
WORKDIR /app/hcs
RUN git apply /app/standard-mode.patch
RUN opam install -y . --deps-only \
 && opam install -y repodb repodb-postgresql climate yojson \
 && opam exec -- dune build arena/server/arena.exe

RUN mkdir -p /app/staging/lib \
 && cp -L _build/default/arena/server/arena.exe /app/staging/server \
 && ldd _build/default/arena/server/arena.exe \
      | awk '/=> \//{print $3}' | sort -u \
      | grep -vE '/(libc|libm|libpthread|libdl|librt|ld-linux)[.-]' \
      | while read -r lib; do cp -Lv "$lib" /app/staging/lib/ 2>/dev/null || true; done \
 && ls -1 /app/staging/lib

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/staging/lib/ /usr/local/lib/
COPY --from=build /app/staging/server /usr/local/bin/server
RUN ldconfig

ENV HCS_ARENA_MODE=standard

EXPOSE 8080 8443 8081 8082
CMD ["/usr/local/bin/server"]
