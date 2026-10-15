FROM rust:1.94-bookworm AS build
WORKDIR /app
ENV RUSTFLAGS="-C target-cpu=native"
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-cpeak /server
CMD ["/server"]
