FROM ocaml/opam:debian-12-ocaml-5.4 AS build

# Released library versions from the public araara opam repository. The
# benchmark application below is compiled against these; nothing is built
# from an unpublished checkout.
ARG HCS_VERSION=0.35.1
ARG SIMDJSONT_VERSION=0.5.3
ARG REPODB_VERSION=0.9.0
ARG PROTOC_VERSION=4.1
ARG OPAM_JOBS=8

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      git libpq-dev libgmp-dev zlib1g-dev libzstd-dev libssl-dev pkg-config m4 cmake \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app && chown opam:opam /app
USER opam
WORKDIR /app

# Point the default repository at the GitHub index (the image ships an older
# snapshot), add the araara repository, and install the released packages.
RUN opam repo set-url default git+https://github.com/ocaml/opam-repository.git \
 && opam repo add araara git+https://tangled.org/gdiazlo.tngl.sh/repo \
 && opam update \
 && opam install -y --jobs=${OPAM_JOBS} \
      "hcs.${HCS_VERSION}" \
      "simdjsont.${SIMDJSONT_VERSION}" \
      "repodb.${REPODB_VERSION}" "repodb-postgresql.${REPODB_VERSION}" \
      "ocaml-protoc.${PROTOC_VERSION}" "pbrt.${PROTOC_VERSION}"

# The benchmark application is part of the submission and reviewable here.
COPY --chown=opam:opam dune-project ./
COPY --chown=opam:opam server ./server
RUN opam exec -- dune build --profile release server/arena.exe

# Stage the executable with the shared libraries it links (OpenSSL, libpq,
# zlib, zstd, gmp) so the runtime image needs no OCaml toolchain.
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

EXPOSE 8080 8443 8081 8082
CMD ["/usr/local/bin/server"]
