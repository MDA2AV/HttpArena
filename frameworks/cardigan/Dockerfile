FROM maven:3.9-eclipse-temurin-26 AS build

WORKDIR /src
COPY pom.xml ./
RUN mvn -q -DskipTests dependency:go-offline
COPY LICENSE ./
COPY src ./src
RUN mvn -q -DskipTests package dependency:copy-dependencies \
    -DincludeScope=runtime -DoutputDirectory=/deps

FROM eclipse-temurin:26-jre

RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl3 \
    && rm -rf /var/lib/apt/lists/*

ARG CARDIGAN_HTTPARENA_MODE=h1
ENV CARDIGAN_HTTPARENA_MODE=${CARDIGAN_HTTPARENA_MODE}

WORKDIR /app
COPY --from=build /src/target/cardigan-httparena.jar ./cardigan-httparena.jar
COPY --from=build /deps ./lib

EXPOSE 8080 8081 8082 8443

ENTRYPOINT ["java", \
    "--enable-preview", \
    "--enable-native-access=ALL-UNNAMED", \
    "--add-opens", "java.base/java.lang=ALL-UNNAMED", \
    "--add-modules", "jdk.incubator.vector", \
    "-Xms512m", "-Xmx2g", \
    "-XX:MaxInlineSize=150", \
    "-XX:FreqInlineSize=600", \
    "-Dcardigan.tls.handshake.max.pending.per.loop=256", \
    "-cp", "/app/cardigan-httparena.jar:/app/lib/*", \
    "dev.cardigan.httparena.HttpArenaMain"]
