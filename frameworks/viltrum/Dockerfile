FROM debian:bookworm-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends ca-certificates curl unzip git gcc libc6-dev && \
    rm -rf /var/lib/apt/lists/*

# V 0.5.2 release (the version viltrum's CI pins) and viltrum at a release tag.
RUN curl -fsSL -o /tmp/v.zip https://github.com/vlang/v/releases/download/0.5.2/v_linux.zip && \
    unzip -q /tmp/v.zip -d /opt && rm /tmp/v.zip
ENV PATH=/opt/v:$PATH

ARG VILTRUM_REF=v1.10.0
RUN git clone --depth 1 --branch ${VILTRUM_REF} https://github.com/Tuntii/viltrum /root/.vmodules/viltrum

WORKDIR /app
COPY main.v ./
RUN v -prod -o server main.v

FROM debian:bookworm-slim
COPY --from=build /app/server /server
EXPOSE 8080 8081 9000
CMD ["/server"]
