FROM sbtscala/scala-sbt:eclipse-temurin-21.0.11_10_1.12.15_3.3.8 AS build
WORKDIR /app
COPY build.sbt .
COPY project/build.properties project/plugins.sbt ./project/
RUN sbt update
COPY src ./src
RUN sbt assembly

FROM eclipse-temurin:25-jre-alpine
WORKDIR /app
COPY --from=build /app/target/app.jar app.jar
EXPOSE 8080 8081 9000
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=60.0", "-Djdk.tls.rejectClientInitiatedRenegotiation=true", "-jar", "app.jar"]
