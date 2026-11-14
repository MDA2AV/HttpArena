# h3spec, the QUIC and HTTP/3 error-case suite: the H/3 compliance suite.
#
# Installed from its release binary, pinned by version and checksum (both set
# by scripts/spec.sh). It is a dynamically linked Haskell binary needing libgmp
# and zlib on top of libc. h3spec takes no path: it sends malformed QUIC and
# HTTP/3 traffic and checks the error the server closes with.
FROM debian:bookworm-slim

ARG H3SPEC_VERSION
ARG H3SPEC_SHA256
RUN test -n "$H3SPEC_VERSION" && test -n "$H3SPEC_SHA256" \
    || { echo "H3SPEC_VERSION and H3SPEC_SHA256 are required"; exit 1; }

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libgmp10 zlib1g \
    && curl -fsSL -o /usr/local/bin/h3spec \
        "https://github.com/kazu-yamamoto/h3spec/releases/download/${H3SPEC_VERSION}/h3spec-linux-x86_64" \
    && echo "${H3SPEC_SHA256}  /usr/local/bin/h3spec" | sha256sum -c - \
    && chmod +x /usr/local/bin/h3spec \
    && apt-get purge -y curl && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["h3spec"]
