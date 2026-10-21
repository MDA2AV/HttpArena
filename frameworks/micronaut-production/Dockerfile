FROM eclipse-temurin:27-jdk AS build
ARG MAVEN_VERSION=3.9.16
ARG MAVEN_SHA512=831a8591fe20c8243b1dbe7d71e3244f31d1665b0804b2e825e38cbbe5ce0cafb8338851f90780735568773e0a6cd07bbec107cda0b896b008b861075358b6f6
RUN curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o /tmp/maven.tar.gz \
    && echo "${MAVEN_SHA512}  /tmp/maven.tar.gz" | sha512sum -c - \
    && mkdir -p /usr/share/maven \
    && tar -xzf /tmp/maven.tar.gz -C /usr/share/maven --strip-components=1 \
    && rm /tmp/maven.tar.gz
ENV PATH="/usr/share/maven/bin:${PATH}"
WORKDIR /app
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q clean package -DskipTests

FROM eclipse-temurin:27-jre
WORKDIR /app
COPY --from=build /app/target/micronaut-production-httparena.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
