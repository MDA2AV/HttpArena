FROM swift:6.2-jammy AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev zlib1g-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Package.swift .
COPY Sources ./Sources
RUN mkdir -p src && echo 'import CSQLite; import CZlib; print("stub")' > src/main.swift && \
    swift build -c release 2>/dev/null || true && \
    rm -rf src/
COPY src ./src
RUN swift build -c release -Xswiftc -O -Xswiftc -cross-module-optimization

FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 libcurl4 libxml2 zlib1g && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/lib/swift/linux/lib*.so /usr/lib/swift/linux/
COPY --from=build /app/.build/release/Server /server
EXPOSE 8080
CMD ["/server", "serve", "--env", "production"]
