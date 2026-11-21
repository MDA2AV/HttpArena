FROM docker.io/library/clojure:temurin-27-tools-deps-resolute@sha256:91b4f2e729c408e8ed1311d0bb6d7717ee72544d9a57cfd872f105ade75bb068

RUN apt-get update && apt-get install --no-install-recommends --yes openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY deps.edn ./
RUN clojure -X:deps prep

COPY src ./src

CMD ["sh", "-ec", "openssl pkcs12 -export -out /tmp/server.p12 -inkey /certs/server.key -in /certs/server.crt -passout pass:httparena && exec clojure -M -m httparena.pedestal.core"]
