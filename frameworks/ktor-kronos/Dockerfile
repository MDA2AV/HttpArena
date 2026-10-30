# ktor-kronos: Ktor with the kron engine (ktor-server-kron), which lives in the MDA2AV/ktor fork and is published
# nowhere yet. The fork and kron come in at pinned commits and are built from source. To build trees that are not
# pushed, replace either fetch with a checkout:
#   docker build --build-context kron=<kron tree> --build-context ktor=<fork tree> -t httparena-ktor-kronos frameworks/ktor-kronos
FROM gradle:9.8.2-jdk25 AS fetch
ARG KRON_COMMIT=ec56ef3f0523f95f54f121bbfcb4ecbcb5bb392e
ARG KTOR_COMMIT=2e8af076ae570e5b254e41c5cca14db2409d7fa4
WORKDIR /src
RUN git init -q kron && cd kron \
 && git remote add origin https://github.com/MDA2AV/kron.git \
 && git fetch -q --depth 1 origin "${KRON_COMMIT}" \
 && git checkout -q FETCH_HEAD \
 && rm -rf .git
RUN git init -q ktor && cd ktor \
 && git remote add origin https://github.com/MDA2AV/ktor.git \
 && git fetch -q --depth 1 origin "${KTOR_COMMIT}" \
 && git checkout -q FETCH_HEAD \
 && rm -rf .git

FROM scratch AS kron
COPY --from=fetch /src/kron /

FROM scratch AS ktor
COPY --from=fetch /src/ktor /

# Kotlin/Native: the first build downloads its toolchain (compiler, LLVM, a glibc sysroot) into ~/.konan.
FROM gradle:9.8.2-jdk25 AS build

# kron and its HTTP/1.1 parser into the local Maven repository the fork reads, built with the fork's Kotlin (2.3): a
# compiler cannot read libraries a newer one made. kron's BoringSSL travels inside its interop library.
COPY --from=kron / /kron
WORKDIR /kron
RUN gradle --no-daemon -q -PkotlinVersion=2.3.21 :kron:publishToMavenLocal :glyph11:publishToMavenLocal

# The arena app, as a project of the fork's own build.
COPY --from=ktor / /ktor
COPY app /ktor/httparena-ktor-kronos
WORKDIR /ktor
RUN echo 'include(":httparena-ktor-kronos")' >> settings.gradle.kts \
 && ./gradlew --no-daemon -q -Pktor.develocity.skipBuildScans=true :httparena-ktor-kronos:linkReleaseExecutableLinuxX64

# One native binary; it needs nothing but glibc. The bench harness runs containers with --security-opt
# seccomp=unconfined, which io_uring_setup and io_uring_enter need.
FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /ktor/httparena-ktor-kronos/build/bin/linuxX64/releaseExecutable/ktor-kronos.kexe ./ktor-kronos
EXPOSE 8080
ENTRYPOINT ["/app/ktor-kronos"]
