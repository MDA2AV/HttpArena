FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
# wastnet-mvc is pinned to a SNAPSHOT (1.0.3-SNAPSHOT); `dependency:go-offline`
# cannot resolve snapshots, so skip it and let `mvn package` fetch deps (incl.
# the snapshot) directly. The snapshot repo is declared in pom.xml.
COPY src ./src
RUN mvn -B -q package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/wastnet-httparena.jar app.jar
EXPOSE 8080 8081 8082 8443
ENTRYPOINT ["java", "-jar", "app.jar"]
