FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /app
COPY pom.xml .
# Not go-offline: it also fetches optional transitive deps, and netty's epoll pom has
# one whose classifier is an unset ${os.detected...} property, so it can never resolve.
RUN mvn -B -q dependency:resolve dependency:resolve-plugins
COPY src ./src
RUN mvn -B -q clean package -DskipTests

# Oracle GraalVM in JIT mode: HotSpot with the Graal compiler (libgraal) in place of C2,
# which is this distribution's default, so no compiler flags are set.
FROM container-registry.oracle.com/graalvm/jdk:25.0.5.1
WORKDIR /app
COPY --from=build /app/target/vertx-httparena.jar app.jar
EXPOSE 8080 8082
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseG1GC", \
  "-XX:+AlwaysPreTouch", \
  "--enable-native-access=ALL-UNNAMED", \
  "-Dvertx.disableDnsResolver=true", \
  "-jar", "app.jar"]
