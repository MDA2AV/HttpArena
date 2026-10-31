# kron - edixoi on kron, on either runtime:
#   KRON_RUNTIME=native  one Kotlin/Native binary, BoringSSL linked into it
#   KRON_RUNTIME=jvm     the same app as a jar on JDK 25, kron reaching io_uring and BoringSSL through the FFM API
# The knob is the ARG below, or `docker build --build-arg KRON_RUNTIME=...`. kron is not published anywhere yet: its
# source at a pinned commit of its repo, BoringSSL included. To build a tree that is not pushed, replace the kron stage
# with a checkout:
#   docker build --build-context kron=<kron checkout> -t httparena-kron frameworks/kron
ARG KRON_RUNTIME=jvm

FROM gradle:9.8.2-jdk25 AS kron-fetch
ARG KRON_COMMIT=02f662f688aee3a73337c644e7a4841bf279d936
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

FROM build AS build-native
RUN gradle linkReleaseExecutableLinuxX64 --no-daemon -q -Pkron=/kron

FROM build AS build-jvm
RUN gradle jvmFatJar --no-daemon -q -Pkron=/kron

# One native binary with BoringSSL inside; it needs nothing but glibc. The bench harness runs containers with
# --security-opt seccomp=unconfined, which io_uring_setup and io_uring_enter need.
FROM debian:bookworm-slim AS runtime-native
WORKDIR /app
COPY --from=build-native /source/build/bin/linuxX64/releaseExecutable/kron-arena.kexe ./kron-arena
EXPOSE 8080 8081
ENTRYPOINT ["/app/kron-arena"]

# The jar on JDK 25, launched as edixoi-kt is; kron maps the BoringSSL its jar carries.
FROM eclipse-temurin:25-jre AS runtime-jvm
WORKDIR /app
COPY --from=build-jvm /source/build/libs/kron-arena.jar ./kron-arena.jar
EXPOSE 8080 8081
ENTRYPOINT ["java", "--enable-native-access=ALL-UNNAMED", "-jar", "/app/kron-arena.jar"]

FROM runtime-${KRON_RUNTIME}
