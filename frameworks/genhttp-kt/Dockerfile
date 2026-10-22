FROM gradle:9.8.2-jdk25 AS build
WORKDIR /source

COPY settings.gradle.kts build.gradle.kts ./
RUN gradle dependencies --no-daemon -q

COPY src ./src
RUN gradle installDist --no-daemon -q

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /source/build/install/genhttp-kt/lib ./lib

EXPOSE 8080 8081 8443
ENTRYPOINT ["java", "--enable-native-access=ALL-UNNAMED", "-cp", "/app/lib/*", "genhttp.ProgramKt"]
