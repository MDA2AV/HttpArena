FROM python:3.9-bullseye
RUN apt-get update; apt-get install libpq-dev python3-dev libev-dev -y
WORKDIR /app
COPY requirements.txt .
RUN pip3 install -U pip
RUN pip3 install -r requirements.txt
COPY . .
EXPOSE 8080
CMD [ "python3", "app.py" ]
