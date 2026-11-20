FROM rust:1.95-bookworm AS build
WORKDIR /work
ENV RUSTFLAGS="-C target-cpu=native"
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
RUN cargo build --release --locked

FROM debian:bookworm-slim
COPY --from=build /work/target/release/httparena-proa /usr/local/bin/httparena-proa
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/httparena-proa"]
