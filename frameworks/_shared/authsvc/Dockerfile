# Multi-stage Rust build for the shared production-stack auth sidecar.
# Stage 1 compiles a musl-statically-linked binary; stage 2 drops it into
# a scratch image. Final image is ~5 MB. Build is cached via a pre-fetch
# step so subsequent iterations on src/main.rs don't re-download the crate
# dependency graph.
FROM rust:1-alpine AS build
WORKDIR /build
RUN apk add --no-cache musl-dev pkgconfig

# Prime the dep cache: build against an empty main.rs so cargo downloads
# and compiles the dependency graph once. Actual src/ changes below don't
# invalidate this layer.
COPY Cargo.toml .
RUN mkdir src && echo 'fn main() {}' > src/main.rs && \
    cargo build --release && \
    rm -rf src target/release/deps/authsvc*

# Now add the real source and rebuild.
COPY src ./src
RUN cargo build --release && \
    strip target/release/authsvc

FROM alpine:3.20
# ca-certificates are needed if authsvc ever connects to something over
# TLS. Not strictly required for the current Redis-over-TCP flow, but
# cheap and avoids surprises.
RUN apk add --no-cache ca-certificates
COPY --from=build /build/target/release/authsvc /usr/local/bin/authsvc
EXPOSE 9090
ENTRYPOINT ["/usr/local/bin/authsvc"]
