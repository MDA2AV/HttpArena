FROM clojure:temurin-21-lein AS builder
WORKDIR /app
COPY project.clj ./
COPY resources ./resources
RUN lein deps
COPY src ./src
RUN lein with-profile uberjar uberjar

FROM eclipse-temurin:25-jre
RUN mkdir -p /data/static
WORKDIR /app
COPY --from=builder /app/target/aleph-bench-0.1.0-standalone.jar /app/app.jar

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]
