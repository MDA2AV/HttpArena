FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev pkgconfig openssl-dev openssl-libs-static && rustup target add x86_64-unknown-linux-musl
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release --target x86_64-unknown-linux-musl && rm -rf src/ target/x86_64-unknown-linux-musl/release/deps/toxi_arena* target/x86_64-unknown-linux-musl/release/toxi-arena
COPY src ./src
RUN cargo build --release --target x86_64-unknown-linux-musl

FROM alpine:3.19
COPY --from=build /app/target/x86_64-unknown-linux-musl/release/toxi-arena /server
EXPOSE 8080
CMD ["/server"]
