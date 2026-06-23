FROM gradle:9.5.1-jdk21-corretto AS build
WORKDIR /app
COPY build.gradle.kts settings.gradle.kts gradle.properties ./
COPY gradle/libs.versions.toml ./gradle/
RUN gradle dependencies --no-daemon -q 2>/dev/null || true
COPY src ./src
RUN gradle buildFatJar --no-daemon -q

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/build/libs/ktor-ghost-httparena.jar .
EXPOSE 8080 8443
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseG1GC", \
  "-XX:+UseNUMA", \
  "-XX:+AlwaysPreTouch", \
  "-XX:-OmitStackTraceInFastThrow", \
  "-Dio.netty.transport.noNative=false", \
  "-Dio.netty.buffer.checkBounds=false", \
  "-Dio.netty.buffer.checkAccessible=false", \
  "-Dio.netty.allocator.maxOrder=10", \
  "-Dio.netty.leakDetection.level=disabled", \
  "-Dio.netty.recycler.maxCapacityPerThread=4096", \
  "-Dio.netty.eventLoopThreads=0", \
  "-jar", "ktor-ghost-httparena.jar"]
