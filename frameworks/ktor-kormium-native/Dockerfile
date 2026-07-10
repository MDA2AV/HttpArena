# The produced executable is Kotlin/Native linuxX64, so the build (and the
# libpq it links against) must be amd64 regardless of the docker host arch.
FROM --platform=linux/amd64 gradle:9.5.1-jdk21 AS build
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY build.gradle.kts settings.gradle.kts gradle.properties ./
RUN gradle help --no-daemon -q 2>/dev/null || true
COPY src ./src
RUN gradle linkReleaseExecutableLinuxX64 --no-daemon -q

FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/build/bin/linuxX64/releaseExecutable/ktor-kormium-native-httparena.kexe ./server
EXPOSE 8080
ENTRYPOINT ["/app/server"]
