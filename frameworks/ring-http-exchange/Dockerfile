FROM clojure:temurin-25-lein-trixie AS builder
WORKDIR /app
COPY project.clj ./
COPY resources ./resources
RUN lein deps
COPY src ./src
RUN lein with-profile uberjar uberjar

FROM container-registry.oracle.com/graalvm/jdk:25
RUN mkdir -p /data/static
WORKDIR /app
COPY --from=builder /app/target/ring-0.1.0-standalone.jar /app/app.jar

EXPOSE 8080 8081

ENTRYPOINT ["java", "-jar", "app.jar"]