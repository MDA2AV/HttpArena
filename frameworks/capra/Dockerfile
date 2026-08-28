FROM docker.io/library/clojure:tools-deps-trixie-slim

WORKDIR /app

COPY deps.edn ./
RUN clojure -P

COPY src ./src
COPY capra-chunk-fragmentation.patch ./
# Capra 0.1.4 counts the chunk-size line as available body bytes. Overlay the
# corrected namespace until the fix is available in a release.
RUN git clone --depth 1 --branch 0.1.4 https://github.com/weavejester/capra.git /tmp/capra \
    && git -C /tmp/capra apply /app/capra-chunk-fragmentation.patch \
    && mkdir -p src/capra \
    && cp /tmp/capra/src/capra/http.clj src/capra/http.clj \
    && rm -rf /tmp/capra capra-chunk-fragmentation.patch

CMD ["clojure", "-M", "-m", "httparena.capra.core"]
