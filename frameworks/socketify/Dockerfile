FROM python:3.13-slim

# socketify ships a prebuilt libsocketify that links libuv at runtime; without
# it the import dies with "libuv.so.1: cannot open shared object file".
RUN apt-get update && apt-get install -y --no-install-recommends libuv1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./

EXPOSE 8080 8081
CMD ["python3", "app.py"]
