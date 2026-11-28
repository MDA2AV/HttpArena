FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /app
COPY . .
RUN mvn package -DskipTests -q

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /app/target/quarkus-app /app
EXPOSE 8080 8443
# No -XX:-StackTraceInThrowable: Netty 4.2 (Quarkus 4) guards some static
# initializers, Http2CodecUtil among them, with LeakPresenceDetector, which
# looks for <clinit> in Thread.getStackTrace(). With that flag the trace is
# empty, the class fails to initialize and every HTTP/2 connection dies.
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseParallelGC", \
  "-XX:+UseNUMA", \
  "-Dio.netty.buffer.checkBounds=false", \
  "-Dio.netty.buffer.checkAccessible=false", \
  "-Dvertx.disableURIValidation=true", \
  "-Dvertx.disableHttpHeadersValidation=true", \
  "-Dvertx.disableMetrics=true", \
  "-Dvertx.disableWebsockets=true", \
  "-Dvertx.threadChecks=false", \
  "-Dvertx.disableContextTimings=true", \
  "-jar", "quarkus-run.jar"]
