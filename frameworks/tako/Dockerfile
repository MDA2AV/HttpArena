FROM rust:1.99-trixie AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release --locked

FROM debian:trixie-slim
COPY --from=build /app/target/release/httparena-tako /server
EXPOSE 8080 8081 8082 8443/tcp 8443/udp
CMD ["/server"]
