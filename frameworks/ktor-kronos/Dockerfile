# ktor-kronos: Ktor on the JVM with the kron engine (ktor-server-kron), from the MDA2AV/ktor fork. Neither the fork nor
# kron is published, so both are built here at pinned commits.
FROM gradle:9.8.2-jdk25 AS build
ARG KRON_COMMIT=e595febb71cde64e39a86b01bebb4343249d515a
ARG KTOR_COMMIT=38ad0b8cf084443d686b9e0c6c2f07460a6d1f19
WORKDIR /src
RUN git init -q kron && cd kron && git remote add origin https://github.com/MDA2AV/kron.git \
 && git fetch -q --depth 1 origin ${KRON_COMMIT} && git checkout -q FETCH_HEAD
RUN git init -q ktor && cd ktor && git remote add origin https://github.com/MDA2AV/ktor.git \
 && git fetch -q --depth 1 origin ${KTOR_COMMIT} && git checkout -q FETCH_HEAD

# kron and its HTTP/1.1 parser into the local Maven repository the fork reads, built with the fork's Kotlin: a compiler
# cannot read libraries a newer one made.
RUN cd kron && gradle --no-daemon -q -PkotlinVersion=2.3.21 :kron:publishToMavenLocal :glyph11:publishToMavenLocal

COPY app ktor/ktor-httparena-kronos
RUN cd ktor && echo 'include(":ktor-httparena-kronos")' >> settings.gradle.kts \
 && ./gradlew --no-daemon -q -Pktor.develocity.skipBuildScans=true :ktor-httparena-kronos:jvmFatJar

FROM eclipse-temurin:25-jre
COPY --from=build /src/ktor/ktor-httparena-kronos/build/libs/ktor-kronos.jar /app/ktor-kronos.jar
EXPOSE 8080 8081
ENTRYPOINT ["java", "-jar", "/app/ktor-kronos.jar"]
