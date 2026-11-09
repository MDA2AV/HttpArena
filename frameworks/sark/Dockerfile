FROM rust:1.98.1-slim-bookworm@sha256:ff521445a372125ed4f76e1453a1f8098f2d05332d1601d30db1c1f62757e730 AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
ENV RUSTC_BOOTSTRAP=1
COPY <<'EOF' /usr/local/cargo/config.toml
[build]
jobs = 2
rustdocflags = []

[unstable]
profile-rustflags = true

[profile.dev]
rustflags = ["-Znext-solver=globally"]

[profile.release]
rustflags = ["-Znext-solver=globally"]

[profile.dev.package."registry+https://github.com/rust-lang/crates.io-index#ml-kem@0.3.2"]
rustflags = ["-Znext-solver=coherence"]

[profile.release.package."registry+https://github.com/rust-lang/crates.io-index#ml-kem@0.3.2"]
rustflags = ["-Znext-solver=coherence"]
EOF
WORKDIR /build
COPY . .
RUN cargo build --release --locked -p httparena-sark --bin httparena-sark

FROM debian:bookworm-slim
COPY --from=build /build/target/release/httparena-sark /server
ENTRYPOINT ["/server"]
