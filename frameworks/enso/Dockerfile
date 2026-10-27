FROM docker.io/library/clojure:temurin-26-tools-deps-trixie@sha256:cdb48987feccf867d2bbc45a73ab697e32eb9e3c79779d68963e99b91d792d0d

WORKDIR /app

COPY deps.edn ./
RUN clojure -X:deps prep

COPY src ./src
RUN mkdir classes && clojure -M:aot -e "(compile 'httparena.enso.core)"

CMD ["clojure", "-J--enable-native-access=ALL-UNNAMED", "-M:aot", "-m", "httparena.enso.core"]
