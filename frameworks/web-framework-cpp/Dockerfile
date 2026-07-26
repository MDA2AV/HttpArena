FROM ubuntu:26.04 AS build

RUN apt update
RUN apt install -y uuid-dev cmake gcc g++ git unzip zip wget ninja-build

COPY web_framework_benchmark/ /app

WORKDIR /app

RUN mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=bin -DCMAKE_CXX_FLAGS="-march=native" -DCMAKE_C_FLAGS="-march=native" -G "Ninja" .. && cmake --build . -j && cmake --install .

FROM ubuntu:26.04

ENV LD_LIBRARY_PATH=/app

COPY --from=build /app/build/bin /app

WORKDIR /app

CMD ["./server"]
