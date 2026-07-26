FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn package -DskipTests

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /app/target/server.jar /app/server.jar
EXPOSE 8082
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseParallelGC", \
  "-XX:+UseNUMA", \
  "-XX:-StackTraceInThrowable", \
  "-Dio.netty.buffer.checkBounds=false", \
  "-Dio.netty.buffer.checkAccessible=false", \
  "-Dvertx.disableURIValidation=true", \
  "-Dvertx.disableHttpHeadersValidation=true", \
  "-Dvertx.disableMetrics=true", \
  "-Dvertx.disableWebsockets=true", \
  "-Dvertx.threadChecks=false", \
  "-Dvertx.disableContextTimings=true", \
  "-jar", "server.jar"]
