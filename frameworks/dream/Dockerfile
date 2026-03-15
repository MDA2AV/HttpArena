FROM ocaml/opam:debian-12-ocaml-5.2 AS build

# Switch to root to install system deps
USER root
RUN apt-get update && apt-get install -y \
    pkg-config libev-dev libsqlite3-dev libssl-dev libgmp-dev zlib1g-dev gcc \
    && rm -rf /var/lib/apt/lists/*

# Build SO_REUSEPORT shim for multi-process support
COPY reuseport.c /tmp/reuseport.c
RUN gcc -shared -fPIC -o /tmp/libreuseport.so /tmp/reuseport.c -ldl

# Switch back to opam user
USER opam
WORKDIR /home/opam/app

# Install OCaml dependencies
RUN opam install dream yojson sqlite3 camlzip --yes

# Copy source
COPY --chown=opam:opam src/ ./src/
COPY --chown=opam:opam src/dune-project ./dune-project

# Build
RUN cd src && eval $(opam env) && dune build --release server.exe
RUN cp src/_build/default/server.exe /home/opam/server

# Runtime stage
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y libev4 libsqlite3-0 libssl3 libgmp10 zlib1g && rm -rf /var/lib/apt/lists/*
COPY --from=build /home/opam/server /server
COPY --from=build /tmp/libreuseport.so /usr/lib/libreuseport.so
COPY run.sh /run.sh
RUN chmod +x /run.sh
EXPOSE 8080
ENV LD_PRELOAD=/usr/lib/libreuseport.so
CMD ["/run.sh"]
