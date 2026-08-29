FROM docker.io/library/clojure:tools-deps-trixie-slim

WORKDIR /app

COPY deps.edn ./
RUN clojure -X:deps prep && clojure -P

COPY src ./src

EXPOSE 8080 8081
CMD ["clojure", "-M", "-m", "httparena.reitit.core"]
