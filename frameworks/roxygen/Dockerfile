FROM rust:1.97-bookworm AS build
ENV RUSTFLAGS="-C target-cpu=native"
WORKDIR /arena
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked \
    && cp target/release/roxygen-arena /usr/local/bin/roxygen-arena

FROM debian:bookworm-slim
COPY --from=build /usr/local/bin/roxygen-arena /usr/local/bin/roxygen-arena
RUN groupadd --system --gid 10001 httparena \
    && useradd --system --uid 10001 --gid httparena --no-create-home --shell /usr/sbin/nologin httparena
EXPOSE 8082/tcp 8443/tcp
USER httparena
ENTRYPOINT ["/usr/local/bin/roxygen-arena"]
