FROM gradle:9.5.1-jdk25-corretto AS build
WORKDIR /app
COPY settings.gradle.kts build.gradle.kts ./
RUN gradle dependencies --no-daemon -q > /dev/null 2>&1 || true
COPY src ./src
COPY templates ./templates
RUN gradle installDist --no-daemon -q

# Minimal runtime, following Klite's sample Dockerfile
FROM amazoncorretto:25-alpine AS jre
RUN apk add --no-cache binutils
RUN jlink --output /jre --compress=zip-6 --no-header-files --no-man-pages --strip-debug --add-modules \
    java.base,jdk.httpserver,java.sql,java.net.http,java.naming,java.management

FROM alpine:3.22
WORKDIR /app
COPY --from=jre /jre ./jre
COPY --from=build /app/build/install/klite-httparena/lib ./lib

ENV ENV=prod
ENV LOGGER=WARN
ENV JAVA_TOOL_OPTIONS="-Xss256K -XX:MaxRAMPercentage=60 -XX:+ExitOnOutOfMemoryError"

EXPOSE 8080
ENTRYPOINT ["/app/jre/bin/java", "-cp", "/app/lib/*", "LauncherKt"]
