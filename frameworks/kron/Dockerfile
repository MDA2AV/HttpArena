# kron is not published anywhere yet: its source at a pinned commit of its repo, BoringSSL included (static
# libraries, linked into the binary). To build a tree that is not pushed, replace the kron stage with a checkout:
#   docker build --build-context kron=<kron checkout> -t httparena-kron frameworks/kron
FROM gradle:9.8.2-jdk25 AS kron-fetch
ARG KRON_COMMIT=f7588c6b06158abd5f7cf2f55e29c111e0c5edd3
WORKDIR /kron
RUN git init -q \
 && git remote add origin https://github.com/MDA2AV/kron.git \
 && git fetch -q --depth 1 origin "${KRON_COMMIT}" \
 && git checkout -q FETCH_HEAD \
 && rm -rf .git

FROM scratch AS kron
COPY --from=kron-fetch /kron /

# Kotlin/Native: the first build downloads its toolchain (compiler, LLVM, a glibc 2.19 sysroot) into ~/.konan.
FROM gradle:9.8.2-jdk25 AS build
COPY --from=kron / /kron
WORKDIR /source
COPY settings.gradle.kts build.gradle.kts ./
COPY src ./src
RUN gradle linkReleaseExecutableLinuxX64 --no-daemon -q -Pkron=/kron

# One native binary with BoringSSL inside; it needs nothing but glibc. The bench harness runs containers with
# --security-opt seccomp=unconfined, which io_uring_setup and io_uring_enter need.
FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /source/build/bin/linuxX64/releaseExecutable/kron-arena.kexe ./kron-arena
EXPOSE 8080 8081
ENTRYPOINT ["/app/kron-arena"]
