FROM docker.io/library/clojure:tools-deps-trixie-slim

RUN java -XshowSettings:properties -version 2>&1 | grep -Eq 'java\.specification\.version = 25' \
    && java -version 2>&1 | grep -Eq 'version "25\.'

WORKDIR /app

COPY deps.edn ./
RUN clojure -X:deps prep

COPY src ./src

CMD ["clojure", "-M", "-m", "httparena.http-kit.core"]
