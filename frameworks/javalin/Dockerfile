FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q clean package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/javalin-httparena.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseG1GC", \
  "-XX:+AlwaysPreTouch", \
  "-Dorg.slf4j.simpleLogger.defaultLogLevel=warn", \
  "-jar", "app.jar"]
