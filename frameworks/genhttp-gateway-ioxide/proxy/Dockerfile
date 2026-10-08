# The published GenHTTP Gateway image - the first linux-x64 build that runs on
# the ioxide engine (GenHTTP 11.0.5), pinned by digest. It reads its config from
# /app/config/gateway.yaml and resolves certificates relative to /app/certs.
FROM genhttp/gateway:linux-x64@sha256:c0f3520e1500b1208d40009fa0c68bda500f4095beed22a62aef1e5e42982e9b

# gateway.yaml (TLS + h2) or gateway-h3.yaml (adds QUIC on the same port)
ARG CONFIG=gateway.yaml

COPY ${CONFIG} /app/config/gateway.yaml

EXPOSE 8443 8443/udp
