FROM rust:1.94 AS build
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release \
    && rm -rf src/ target/release/httparena-ntex* target/release/deps/httparena_ntex*
COPY src ./src
# No target-cpu=native and no LTO: this entry has a history of tripping a rustc
# SIGSEGV and a GCC ICE with both enabled, and neither is needed for the
# workload here.
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-ntex /server
EXPOSE 8080
CMD ["/server"]
