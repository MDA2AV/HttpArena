FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080 8081
CMD [ "python3", "launcher.py", "gunicorn", "--config", "gunicorn_conf.py", "app:app" ]
