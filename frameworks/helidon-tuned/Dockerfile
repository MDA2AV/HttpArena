FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /app/target/helidon-httparena-tuned.jar app.jar
COPY --from=build /app/target/libs ./libs
EXPOSE 8080 8081 8443
ENTRYPOINT ["java", "-jar", "app.jar"]
