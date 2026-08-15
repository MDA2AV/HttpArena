FROM docker.io/library/clojure:tools-deps-trixie-slim

WORKDIR /app

COPY deps.edn ./
RUN clojure -X:deps prep

COPY src ./src

CMD ["clojure", "-M", "-m", "httparena.pedestal.core"]
