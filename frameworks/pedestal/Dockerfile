FROM docker.io/library/clojure:temurin-26-tools-deps-trixie@sha256:cdb48987feccf867d2bbc45a73ab697e32eb9e3c79779d68963e99b91d792d0d

RUN apt-get update && apt-get install --no-install-recommends --yes openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY deps.edn ./
RUN clojure -X:deps prep

COPY src ./src

CMD ["sh", "-ec", "openssl pkcs12 -export -out /tmp/server.p12 -inkey /certs/server.key -in /certs/server.crt -passout pass:httparena && exec clojure -M -m httparena.pedestal.core"]
