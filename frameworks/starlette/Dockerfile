FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py launcher.py ./
EXPOSE 8080
CMD [ "python3", "launcher.py", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080", "--loop", "uvloop", "--log-level", "critical", "--no-server-header", "--header", "Server:Starlette" ]
