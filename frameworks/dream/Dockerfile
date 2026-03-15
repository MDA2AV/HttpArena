FROM ocaml/opam:debian-12-ocaml-5.2 AS build

# Switch to root to install system deps
USER root
RUN apt-get update && apt-get install -y \
    pkg-config libev-dev libsqlite3-dev libssl-dev libgmp-dev \
    && rm -rf /var/lib/apt/lists/*

# Switch back to opam user
USER opam
WORKDIR /home/opam/app

# Install OCaml dependencies
RUN opam install dream yojson sqlite3 --yes

# Copy source
COPY --chown=opam:opam src/ ./src/
COPY --chown=opam:opam src/dune-project ./dune-project

# Build
RUN cd src && eval $(opam env) && dune build --release server.exe
RUN cp src/_build/default/server.exe /home/opam/server

# Runtime stage
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y libev4 libsqlite3-0 libssl3 libgmp10 && rm -rf /var/lib/apt/lists/*
COPY --from=build /home/opam/server /server
EXPOSE 8080
CMD ["/server"]
