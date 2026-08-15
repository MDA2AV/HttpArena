FROM python:3.9-bullseye
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq-dev python3-dev libev-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip3 install -U pip
RUN pip3 install -r requirements.txt
COPY . .
EXPOSE 8080
CMD [ "python3", "app.py" ]
