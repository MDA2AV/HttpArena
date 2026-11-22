FROM rust:1.97-bookworm AS build
ENV RUSTFLAGS="-C target-cpu=native"
WORKDIR /arena
COPY Cargo.toml Cargo.lock ./
COPY src ./src
# A ferroxygen release changes these crates.io index entries, which reruns the
# update and build below against the newest 0.1 release.
ADD https://index.crates.io/fe/rr/ferroxygen_codec /tmp/ferroxygen-index/
ADD https://index.crates.io/fe/rr/ferroxygen_core /tmp/ferroxygen-index/
ADD https://index.crates.io/fe/rr/ferroxygen_http1 /tmp/ferroxygen-index/
ADD https://index.crates.io/fe/rr/ferroxygen_http2 /tmp/ferroxygen-index/
ADD https://index.crates.io/fe/rr/ferroxygen_runtime /tmp/ferroxygen-index/
ADD https://index.crates.io/fe/rr/ferroxygen_server /tmp/ferroxygen-index/
ADD https://index.crates.io/fe/rr/ferroxygen_session /tmp/ferroxygen-index/
ADD https://index.crates.io/fe/rr/ferroxygen_transport /tmp/ferroxygen-index/
RUN cargo update $(sed -n 's/^name = "\(ferroxygen_[a-z0-9_]*\)"/-p \1/p' Cargo.lock) \
    && cargo build --release --locked \
    && cp target/release/roxygen-arena /usr/local/bin/roxygen-arena

FROM debian:bookworm-slim
COPY --from=build /usr/local/bin/roxygen-arena /usr/local/bin/roxygen-arena
RUN groupadd --system --gid 10001 httparena \
    && useradd --system --uid 10001 --gid httparena --no-create-home --shell /usr/sbin/nologin httparena
EXPOSE 8082/tcp 8443/tcp
USER httparena
ENTRYPOINT ["/usr/local/bin/roxygen-arena"]
