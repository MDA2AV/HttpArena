FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN mkdir -p gen && python -m grpc_tools.protoc -I proto --python_out=gen --grpc_python_out=gen proto/benchmark.proto
EXPOSE 8080 8081 8082 8443/tcp 8443/udp
CMD ["python3", "app.py"]
