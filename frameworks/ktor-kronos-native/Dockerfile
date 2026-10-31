# ktor-kronos-native: Ktor with the kron engine (ktor-server-kron), which lives in the MDA2AV/ktor fork, as one
# Kotlin/Native binary; the ktor-kronos entry runs the same app on the JVM. The fork and kron are published nowhere
# yet: they come in at pinned commits and are built from source. To build trees that are not pushed, replace either
# fetch with a checkout:
#   docker build --build-context kron=<kron tree> --build-context ktor=<fork tree> -t httparena-ktor-kronos-native frameworks/ktor-kronos-native

# One fetch per tree, so that a --build-context in place of either skips its clone.
FROM gradle:9.8.2-jdk25 AS fetch-kron
ARG KRON_COMMIT=02f662f688aee3a73337c644e7a4841bf279d936
WORKDIR /src
RUN git init -q kron && cd kron \
 && git remote add origin https://github.com/MDA2AV/kron.git \
 && git fetch -q --depth 1 origin "${KRON_COMMIT}" \
 && git checkout -q FETCH_HEAD \
 && rm -rf .git

FROM gradle:9.8.2-jdk25 AS fetch-ktor
ARG KTOR_COMMIT=033263e0c5e832051b69e1f084207ce44488e8d0
WORKDIR /src
RUN git init -q ktor && cd ktor \
 && git remote add origin https://github.com/MDA2AV/ktor.git \
 && git fetch -q --depth 1 origin "${KTOR_COMMIT}" \
 && git checkout -q FETCH_HEAD \
 && rm -rf .git

FROM scratch AS kron
COPY --from=fetch-kron /src/kron /

FROM scratch AS ktor
COPY --from=fetch-ktor /src/ktor /

# Kotlin/Native: the first build downloads its toolchain (compiler, LLVM, a glibc sysroot) into ~/.konan.
FROM gradle:9.8.2-jdk25 AS build

# kron and its HTTP/1.1 parser into the local Maven repository the fork reads, built with the fork's Kotlin (2.3): a
# compiler cannot read libraries a newer one made. kron's BoringSSL travels inside its interop library.
COPY --from=kron / /kron
WORKDIR /kron
RUN gradle --no-daemon -q -PkotlinVersion=2.3.21 :kron:publishToMavenLocal :glyph11:publishToMavenLocal

# The arena app, as a project of the fork's own build.
COPY --from=ktor / /ktor
COPY app /ktor/ktor-httparena-kronos
WORKDIR /ktor
RUN echo 'include(":ktor-httparena-kronos")' >> settings.gradle.kts \
 && ./gradlew --no-daemon -q -Pktor.develocity.skipBuildScans=true :ktor-httparena-kronos:linkReleaseExecutableLinuxX64

# One native binary; it needs nothing but glibc. The bench harness runs containers with --security-opt
# seccomp=unconfined, which io_uring_setup and io_uring_enter need.
FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /ktor/ktor-httparena-kronos/build/bin/linuxX64/releaseExecutable/ktor-kronos.kexe ./ktor-kronos
EXPOSE 8080 8081
ENTRYPOINT ["/app/ktor-kronos"]
