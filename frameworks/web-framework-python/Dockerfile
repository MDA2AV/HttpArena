FROM ubuntu:26.04 AS build

RUN apt update
RUN apt install -y uuid-dev cmake gcc g++ git unzip zip wget ninja-build python3 python3-venv python3-pip
RUN python3 -m pip install build --break-system-packages

COPY web_framework_benchmark/ /app

WORKDIR /app

RUN mkdir build && cd build && cmake -DCMAKE_INSTALL_PREFIX=bin -DCMAKE_CXX_FLAGS="-march=native" -DCMAKE_C_FLAGS="-march=native" -G "Ninja" .. && cmake --build . -j && cmake --install .

FROM ubuntu:26.04

ENV LD_LIBRARY_PATH=/app/lib

RUN apt update
RUN apt install -y python3 python3-dev python3-pip

COPY --from=build /app/build/bin /app

WORKDIR /app

RUN python3 -m pip install api/python_api/dist/*.whl --break-system-packages

CMD ["python3", "server.py"]
