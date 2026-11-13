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
#
# `cargo clean -p authsvc` then drops the placeholder's own artifacts, and only
# those, wherever this cargo keeps them. This step used to delete
# target/release/deps/authsvc* by hand. Cargo 1.100 moved each package's
# artifacts to target/release/build/<package>/<hash>/, the glob stopped
# matching, and the build below found the placeholder up to date and shipped
# it: an authsvc that exits 0 at once without a word, so every
# production-stack run failed before measuring anything.
COPY Cargo.toml .
RUN mkdir src && echo 'fn main() {}' > src/main.rs && \
    cargo build --release && \
    cargo clean --release -p authsvc && \
    rm -rf src

# Now add the real source and rebuild. The grep fails the build if the
# placeholder is ever shipped again: the server's startup line is in the
# real binary and nowhere in the empty one.
COPY src ./src
RUN cargo build --release && \
    strip target/release/authsvc && \
    grep -q "authsvc listening on" target/release/authsvc

FROM alpine:3.20
# ca-certificates are needed if authsvc ever connects to something over
# TLS. Not strictly required for the current Redis-over-TCP flow, but
# cheap and avoids surprises.
RUN apk add --no-cache ca-certificates
COPY --from=build /build/target/release/authsvc /usr/local/bin/authsvc
EXPOSE 9090
ENTRYPOINT ["/usr/local/bin/authsvc"]
