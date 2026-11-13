# The Kotlin port of ioxide is not published anywhere yet: its source at a pinned commit of the ioxide repo, with
# the BoringSSL ioxide bundles. To build a tree that is not pushed, replace the ioxide-kt stage with a directory
# holding the same two paths, ioxide/ (kotlin/ioxide) and native/libioxide_boringssl.so:
#   docker build --build-context ioxide-kt=<dir> -t httparena-edixoi-kt frameworks/edixoi-kt
FROM gradle:9.8.2-jdk25 AS ioxide-fetch
ARG IOXIDE_COMMIT=7d41f473798656bec3098ce81b338a3f0deed76d
WORKDIR /ioxide
RUN git init -q \
 && git remote add origin https://github.com/MDA2AV/ioxide.git \
 && git fetch -q --depth 1 origin "${IOXIDE_COMMIT}" \
 && git checkout -q FETCH_HEAD -- kotlin/ioxide src/ioxide/runtimes/linux-x64/native/libioxide_boringssl.so

FROM scratch AS ioxide-kt
COPY --from=ioxide-fetch /ioxide/kotlin/ioxide /ioxide
COPY --from=ioxide-fetch /ioxide/src/ioxide/runtimes/linux-x64/native/libioxide_boringssl.so /native/

FROM gradle:9.8.2-jdk25 AS build
COPY --from=ioxide-kt / /ioxide-kt
WORKDIR /source
COPY settings.gradle.kts build.gradle.kts ./
COPY src ./src
RUN gradle installDist --no-daemon -q

# ioxide drives io_uring through direct libc syscalls over FFM (no liburing, no JNI). The bench harness runs
# containers with --security-opt seccomp=unconfined, which io_uring_setup and io_uring_enter need.
FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /source/build/install/edixoi-kt/lib ./lib
COPY --from=ioxide-kt /native/libioxide_boringssl.so ./native/
EXPOSE 8080 8081
ENTRYPOINT ["java", "--enable-native-access=ALL-UNNAMED", "-Dioxide.boringssl=/app/native/libioxide_boringssl.so", "-cp", "/app/lib/*", "edixoi.ProgramKt"]
