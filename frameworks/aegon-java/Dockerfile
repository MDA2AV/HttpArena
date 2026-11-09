FROM archlinux:latest AS build

RUN pacman -Syu --noconfirm --needed \
    base-devel \
    cmake \
    ninja \
    git \
    liburing \
    glaze \
    openssl \
    libdeflate \
    sqlite \
    postgresql-libs \
    libngtcp2 \
    libnghttp3 \
    protobuf \
    jdk-openjdk \
    maven

ARG AEGON_REPO=https://github.com/UdayKhare09/Aegon.git
ARG AEGON_REF=main
ARG AEGON_COMMIT=5fe9629

WORKDIR /src
RUN echo "Building Aegon commit: ${AEGON_COMMIT}" && \
    git clone --branch "${AEGON_REF}" "${AEGON_REPO}" aegon-src && \
    cd aegon-src && \
    git checkout "${AEGON_COMMIT}"

WORKDIR /src/aegon-src
RUN cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DAEGON_BUILD_TESTS=OFF \
    -DAEGON_BUILD_SAMPLES=OFF \
    -DAEGON_BUILD_BENCHMARKS=OFF \
    -DAEGON_BUILD_C_ABI=ON \
    -DAEGON_ENABLE_NATIVE_TUNING=ON \
    -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build build -j$(nproc) && \
    cmake --install build

WORKDIR /src/aegon-src/bindings/java
RUN mvn clean install -DskipTests

WORKDIR /app
COPY pom.xml ./
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package dependency:copy-dependencies -DskipTests

FROM archlinux:latest

RUN pacman -Syu --noconfirm --needed \
    liburing \
    openssl \
    libdeflate \
    sqlite \
    postgresql-libs \
    jemalloc \
    libngtcp2 \
    libnghttp3 \
    protobuf \
    jre-openjdk-headless && \
    pacman -Scc --noconfirm

ENV LD_PRELOAD=/usr/lib/libjemalloc.so
ENV LD_LIBRARY_PATH=/usr/local/lib

COPY --from=build /usr/local/lib/ /usr/local/lib/
COPY --from=build /app/target/aegon-java-httparena.jar /app/aegon-java-httparena.jar
COPY --from=build /app/target/dependency /app/lib

EXPOSE 8080 8081 8082 8443 8443/udp

CMD ["java", \
    "--enable-native-access=ALL-UNNAMED", \
    "-XX:+UseParallelGC", \
    "-Xms512m", "-Xmx2g", \
    "-Djava.library.path=/usr/local/lib", \
    "-cp", "/app/aegon-java-httparena.jar:/app/lib/*", \
    "httparena.Main"]
