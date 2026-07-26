FROM python:3.13-slim

WORKDIR /app

RUN pip install --no-cache-dir uv slimeweb

RUN slime new arena

WORKDIR /app/arena

RUN slime add asyncpg

COPY main.py /app/arena/main.py

EXPOSE 8080

CMD ["slime","run","main.py"]
