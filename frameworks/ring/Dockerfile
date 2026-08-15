FROM docker.io/library/clojure:tools-deps-trixie-slim

WORKDIR /app

COPY deps.edn ./
RUN clojure -X:deps prep

COPY src ./src
COPY resources ./resources

CMD ["clojure", "-M", "-m", "httparena.ring.core"]
