FROM sbtscala/scala-sbt:eclipse-temurin-21.0.11_10_1.12.15_3.3.8 AS build
WORKDIR /app
COPY build.sbt .
COPY project ./project
RUN sbt update
COPY src ./src
RUN sbt assembly

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/scala-3.3.8/httparena-http4s-assembly-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseG1GC", \
  "-XX:+AlwaysPreTouch", \
  "-jar", "app.jar"]
