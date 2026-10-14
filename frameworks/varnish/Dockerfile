FROM varnish:9.0.3 AS build

USER root
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        curl \
        libclang-dev \
        media-types \
        pkg-config \
        "varnish-dev=$(dpkg-query -W -f='${Version}' varnish)"
# varnish-dev is pinned to the version the image ships (9.0.3-5~trixie): the
# image's apt source also carries 9.1.0 now, and an unpinned varnish-dev picks
# that, which depends on varnish 9.1.0 and conflicts with the installed one.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable -q
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /vmod
COPY vmod/Cargo.toml ./
COPY vmod/src ./src
RUN cargo build --release && \
    cp target/release/libvmod_httparena.so /tmp/libvmod_httparena.so

FROM varnish:9.0.3

COPY --from=build /tmp/libvmod_httparena.so /usr/lib/varnish/vmods/libvmod_httparena.so
COPY --from=build /etc/mime.types /etc/varnish/mime.types
COPY default.vcl /etc/varnish/default.vcl
COPY tls.conf /etc/varnish/tls.conf
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

EXPOSE 8080 8081 8082 8443

ENTRYPOINT ["/entrypoint.sh"]
