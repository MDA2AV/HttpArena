FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
ENV ROBYN_PORT=8080
ENV ROBYN_HOST=0.0.0.0
ENV ROBYN_CLIENT_TIMEOUT=30
ENV ROBYN_KEEP_ALIVE_TIMEOUT=20
CMD [ "python3", "app.py" ]
