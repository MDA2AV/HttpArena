FROM python:3.13-slim

WORKDIR /app

RUN pip install --no-cache-dir uv slimeweb

RUN slime new arena

WORKDIR /app/arena


COPY main.py /app/arena/main.py

EXPOSE 8081

CMD ["slime","run","main.py"]
