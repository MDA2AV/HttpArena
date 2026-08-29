FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q clean package -DskipTests

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /app/target/jooby-httparena.jar app.jar
EXPOSE 8080 8081
ENTRYPOINT ["java", "-XX:+UseZGC", "-jar", "app.jar"]
