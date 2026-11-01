# ktor-kronos-native: Ktor on Kotlin/Native with the kron engine (ktor-server-kron), from the MDA2AV/ktor fork, as one
# native binary. Neither the fork nor kron is published, so both are built here at pinned commits.
FROM gradle:9.8.2-jdk25 AS build
ARG KRON_COMMIT=e595febb71cde64e39a86b01bebb4343249d515a
ARG KTOR_COMMIT=106893873e36efcd937f69281dc2135e73d78368
WORKDIR /src
RUN git init -q kron && cd kron && git remote add origin https://github.com/MDA2AV/kron.git \
 && git fetch -q --depth 1 origin ${KRON_COMMIT} && git checkout -q FETCH_HEAD
RUN git init -q ktor && cd ktor && git remote add origin https://github.com/MDA2AV/ktor.git \
 && git fetch -q --depth 1 origin ${KTOR_COMMIT} && git checkout -q FETCH_HEAD

# kron and its HTTP/1.1 parser into the local Maven repository the fork reads, built with the fork's Kotlin: a compiler
# cannot read libraries a newer one made. The first Kotlin/Native build downloads its toolchain into ~/.konan.
RUN cd kron && gradle --no-daemon -q -PkotlinVersion=2.3.21 :kron:publishToMavenLocal :glyph11:publishToMavenLocal

COPY app ktor/ktor-httparena-kronos
RUN cd ktor && echo 'include(":ktor-httparena-kronos")' >> settings.gradle.kts \
 && ./gradlew --no-daemon -q -Pktor.develocity.skipBuildScans=true :ktor-httparena-kronos:linkReleaseExecutableLinuxX64

# One binary, BoringSSL inside: it needs nothing but glibc.
FROM debian:bookworm-slim
COPY --from=build /src/ktor/ktor-httparena-kronos/build/bin/linuxX64/releaseExecutable/ktor-kronos.kexe /app/ktor-kronos
EXPOSE 8080 8081
ENTRYPOINT ["/app/ktor-kronos"]
