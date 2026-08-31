FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py db.py launcher.py ./

EXPOSE 8080 8081 8082 8443

CMD ["python", "launcher.py"]
