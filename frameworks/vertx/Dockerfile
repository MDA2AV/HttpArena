FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
# Not go-offline: it also fetches optional transitive deps, and netty's epoll pom has
# one whose classifier is an unset ${os.detected...} property, so it can never resolve.
RUN mvn -B -q dependency:resolve dependency:resolve-plugins
COPY src ./src
RUN mvn -B -q clean package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/vertx-httparena.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseG1GC", \
  "-XX:+AlwaysPreTouch", \
  "--enable-native-access=ALL-UNNAMED", \
  "-Dvertx.disableDnsResolver=true", \
  "-jar", "app.jar"]
