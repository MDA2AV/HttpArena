# Ktron and the Kotlin port of ioxide it runs on are not published yet: both from source at pinned commits, with
# the BoringSSL ioxide bundles. To build trees that are not pushed, replace the deps stage with a directory holding
# the same paths - ktron/ (the Ktron repo), ioxide/ (ioxide's kotlin/ioxide) and native/libioxide_boringssl.so:
#   docker build --build-context deps=<dir> -t httparena-ktron frameworks/ktron
FROM gradle:9.8.2-jdk25 AS fetch
ARG KTRON_COMMIT=971aadc8e97f4094df232e3df2692521323a2660
ARG IOXIDE_COMMIT=7d41f473798656bec3098ce81b338a3f0deed76d
WORKDIR /fetch
RUN git init -q ktron && cd ktron \
 && git remote add origin https://github.com/MDA2AV/Ktron.git \
 && git fetch -q --depth 1 origin "${KTRON_COMMIT}" \
 && git checkout -q FETCH_HEAD -- ktron glyph11
RUN git init -q ioxide && cd ioxide \
 && git remote add origin https://github.com/MDA2AV/ioxide.git \
 && git fetch -q --depth 1 origin "${IOXIDE_COMMIT}" \
 && git checkout -q FETCH_HEAD -- kotlin/ioxide src/ioxide/runtimes/linux-x64/native/libioxide_boringssl.so

FROM scratch AS deps
COPY --from=fetch /fetch/ktron/ktron /ktron/ktron
COPY --from=fetch /fetch/ktron/glyph11 /ktron/glyph11
COPY --from=fetch /fetch/ioxide/kotlin/ioxide /ioxide
COPY --from=fetch /fetch/ioxide/src/ioxide/runtimes/linux-x64/native/libioxide_boringssl.so /native/

FROM gradle:9.8.2-jdk25 AS build
COPY --from=deps / /deps
WORKDIR /source
COPY settings.gradle.kts build.gradle.kts ./
COPY src ./src
RUN gradle installDist --no-daemon -q

# ioxide drives io_uring through direct syscalls over FFM, which needs --security-opt seccomp=unconfined (the
# harness runs every container so). Compression is libdeflate and libbrotlienc, also over FFM.
FROM eclipse-temurin:25-jre
RUN apt-get update -q && apt-get install -y -q --no-install-recommends libdeflate0 libbrotli1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /source/build/install/ktron-arena/lib ./lib
COPY --from=deps /native/libioxide_boringssl.so ./native/
EXPOSE 8080 8081
ENTRYPOINT ["java", "--enable-native-access=ALL-UNNAMED", "-Dioxide.boringssl=/app/native/libioxide_boringssl.so", "-cp", "/app/lib/*", "arena.MainKt"]
