FROM sbtscala/scala-sbt:eclipse-temurin-alpine-21.0.11_10_1.12.15_3.3.8 AS build
RUN apk add --no-cache clang gcc
WORKDIR /app
COPY build.sbt .
COPY project ./project
RUN sbt update
COPY src ./src
RUN sbt -batch -J-Xmx4G nativeLink

FROM alpine:3.23
COPY --from=build /app/target/native/server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
