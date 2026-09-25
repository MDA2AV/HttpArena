FROM docker.io/library/clojure:temurin-26-tools-deps-trixie@sha256:cdb48987feccf867d2bbc45a73ab697e32eb9e3c79779d68963e99b91d792d0d


ENV JAVA_TOOL_OPTIONS=--enable-native-access=ALL-UNNAMED

WORKDIR /app

COPY deps.edn ./
RUN clojure -X:deps prep

COPY src ./src

CMD ["clojure", "-M", "-m", "httparena.busker.core"]
