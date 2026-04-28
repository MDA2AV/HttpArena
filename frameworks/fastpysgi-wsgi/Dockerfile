FROM python:3.13-slim-bookworm
RUN apt-get update \
    && apt-get install -y --no-install-recommends git build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080 8081
CMD [ "python", "app.py" ]
