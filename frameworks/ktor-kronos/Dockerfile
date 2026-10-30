# ktor-kronos: Ktor with the kron engine (ktor-server-kron), which lives in the MDA2AV/ktor fork, on either runtime:
#   KRONOS_RUNTIME=native  one Kotlin/Native binary
#   KRONOS_RUNTIME=jvm     the same app as a jar on the JVM, kron reaching io_uring and BoringSSL through FFM
# The knob is the ARG below, or `docker build --build-arg KRONOS_RUNTIME=...`. json-comp needs the JVM, as Ktor has no
# gzip on Kotlin/Native: for native, take it out of meta.json. The fork and kron are published nowhere yet: they come
# in at pinned commits and are built from source. To build trees that are not pushed, replace either fetch with a
# checkout:
#   docker build --build-context kron=<kron tree> --build-context ktor=<fork tree> -t httparena-ktor-kronos frameworks/ktor-kronos
ARG KRONOS_RUNTIME=jvm

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
ARG KTOR_COMMIT=9b2b6ff5d29ecacd2c82894a824828b7490153e1
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
# compiler cannot read libraries a newer one made. Both runtimes' artifacts: kron's BoringSSL travels inside its
# interop library natively, and inside its jar on the JVM.
COPY --from=kron / /kron
WORKDIR /kron
RUN gradle --no-daemon -q -PkotlinVersion=2.3.21 :kron:publishToMavenLocal :glyph11:publishToMavenLocal

# The arena app, as a project of the fork's own build.
COPY --from=ktor / /ktor
COPY app /ktor/ktor-httparena-kronos
WORKDIR /ktor
RUN echo 'include(":ktor-httparena-kronos")' >> settings.gradle.kts

FROM build AS build-native
RUN ./gradlew --no-daemon -q -Pktor.develocity.skipBuildScans=true :ktor-httparena-kronos:linkReleaseExecutableLinuxX64

FROM build AS build-jvm
RUN ./gradlew --no-daemon -q -Pktor.develocity.skipBuildScans=true :ktor-httparena-kronos:jvmFatJar

# One native binary; it needs nothing but glibc. The bench harness runs containers with --security-opt
# seccomp=unconfined, which io_uring_setup and io_uring_enter need.
FROM debian:bookworm-slim AS runtime-native
WORKDIR /app
COPY --from=build-native /ktor/ktor-httparena-kronos/build/bin/linuxX64/releaseExecutable/ktor-kronos.kexe ./ktor-kronos
EXPOSE 8080 8081
ENTRYPOINT ["/app/ktor-kronos"]

# The jar on JDK 25, with the flags the ktor entry runs Netty with. FFM needs native access, which the jar's manifest
# grants as well.
FROM eclipse-temurin:25-jre AS runtime-jvm
WORKDIR /app
COPY --from=build-jvm /ktor/ktor-httparena-kronos/build/libs/ktor-kronos.jar ./ktor-kronos.jar
EXPOSE 8080 8081
# DIAGNOSTICS, temporary: GC pauses, the GC's sizing at start, and each safepoint's time to reach, to stdout.
ENTRYPOINT ["java", "-server", "-XX:+UseG1GC", "-XX:+UseNUMA", "-XX:+AlwaysPreTouch", \
    "-Xlog:gc,gc+init,safepoint:stdout:uptime,tags", \
    "--enable-native-access=ALL-UNNAMED", "-jar", "/app/ktor-kronos.jar"]

FROM runtime-${KRONOS_RUNTIME}
