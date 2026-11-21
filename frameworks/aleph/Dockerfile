FROM docker.io/library/clojure:temurin-27-tools-deps-resolute@sha256:91b4f2e729c408e8ed1311d0bb6d7717ee72544d9a57cfd872f105ade75bb068

WORKDIR /app

COPY deps.edn ./
RUN clojure -X:deps prep

COPY src ./src

CMD ["clojure", "-M", "-m", "aleph-bench.core"]
