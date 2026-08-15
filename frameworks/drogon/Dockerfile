FROM drogonframework/drogon:latest AS build
WORKDIR /app
COPY CMakeLists.txt main.cc ./
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -j$(nproc)

FROM drogonframework/drogon:latest
COPY --from=build /app/build/server /server
EXPOSE 8080
CMD ["/server"]
