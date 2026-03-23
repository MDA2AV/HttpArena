# Build stage
FROM ocaml/opam:debian-12-ocaml-5.3 AS builder

# Switch to root for system deps
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libsqlite3-dev libgmp-dev libffi-dev && \
    rm -rf /var/lib/apt/lists/*

# Switch back to opam user
USER opam
WORKDIR /home/opam/app

# Install OCaml dependencies
RUN opam update && \
    opam install -y vif yojson sqlite3

# Copy source
COPY --chown=opam:opam dune-project ./
COPY --chown=opam:opam src/ src/

# Build
RUN eval $(opam env) && dune build --release src/server.exe

# Runtime stage
FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 libgmp10 libffi8 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /home/opam/app/_build/default/src/server.exe /app/server
COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

EXPOSE 8080

CMD ["/app/run.sh"]
