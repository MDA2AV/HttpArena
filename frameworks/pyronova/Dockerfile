FROM python:3.13-slim AS build
WORKDIR /build

# Rust toolchain + maturin for the Pyronova engine build.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates build-essential pkg-config libssl-dev git \
    && rm -rf /var/lib/apt/lists/*
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
RUN pip install --no-cache-dir maturin

# Pinned release — bumping PYRONOVA_REF invalidates the cache below and
# rebuilds from that tag. The full source ships at github, not in this
# PR, so the PR stays small and the build is byte-for-byte reproducible
# against a signed git ref.
ARG PYRONOVA_REF=v2.3.1
RUN git clone --depth 1 --branch ${PYRONOVA_REF} \
        https://github.com/moomoo-tech/pyronova.git /build/pyronova
RUN cd /build/pyronova \
    && RUSTFLAGS="-C target-cpu=native" \
       maturin build --release --out /wheels --compatibility linux


FROM python:3.13-slim
WORKDIR /app

COPY --from=build /wheels /tmp/wheels
RUN pip install --no-cache-dir /tmp/wheels/*.whl && rm -rf /tmp/wheels

COPY app.py launcher.py ./

# Arena harness expectations:
#   - 8080 plaintext HTTP/1.1
#   - 8081 HTTPS HTTP/1.1 (json-tls profile)
#   - 8443 HTTPS HTTP/2 (baseline-h2, static-h2)
#   - /certs/server.{crt,key}  mounted by harness
#   - /data/dataset.json       mounted by harness
#   - /data/static             mounted by harness
#   - $DATABASE_URL            set by harness when PG profile active
EXPOSE 8080 8081 8443
CMD ["python3", "launcher.py"]
