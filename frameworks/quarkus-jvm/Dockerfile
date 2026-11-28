FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /app/target/quarkus-app /app
EXPOSE 8080 8443
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseParallelGC", \
  "-XX:+UseNUMA", \
  "--sun-misc-unsafe-memory-access=allow", \
  "-Dio.netty.buffer.checkBounds=false", \
  "-Dio.netty.buffer.checkAccessible=false", \
  "-Dvertx.disableURIValidation=true", \
  "-Dvertx.disableHttpHeadersValidation=true", \
  "-Dvertx.disableMetrics=true", \
  "-Dvertx.disableH2c=true", \
  "-Dvertx.disableWebsockets=true", \
  "-Dvertx.threadChecks=false", \
  "-Dvertx.disableContextTimings=true", \
  "-jar", "quarkus-run.jar"]
