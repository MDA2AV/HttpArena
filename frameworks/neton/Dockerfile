# Kotlin/Native compiles to a native executable, so the runtime image carries no
# JDK — only the binary and its libc. The JDK below is Gradle's, not the app's.
#
# The build runs ./gradlew, not the image's own gradle: the wrapper pins the
# exact Gradle the entry is verified against, so the container cannot silently
# build with a different one.
FROM eclipse-temurin:21-jdk AS build
WORKDIR /app

# Warm the Gradle distribution, the Kotlin/Native toolchain and the Maven
# dependencies before the sources land, so editing Main.kt does not re-download
# the konan distribution.
COPY gradlew ./
COPY gradle ./gradle
COPY build.gradle.kts settings.gradle.kts gradle.properties ./
RUN ./gradlew --no-daemon -q dependencies --configuration linuxX64CompileKlibraries 2>/dev/null || true

COPY src ./src
RUN ./gradlew --no-daemon -q linkReleaseExecutableLinuxX64

FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /app/build/bin/linuxX64/releaseExecutable/neton-httparena.kexe /app/server
# Read at startup from the working directory; it sets the arena's port map and
# connection ceiling and outranks the DSL.
COPY config ./config
# 8080 HTTP/1.1, 8082 HTTP/2 cleartext (prior knowledge).
EXPOSE 8080 8082
CMD ["/app/server"]
