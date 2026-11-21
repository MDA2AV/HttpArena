FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends ca-certificates curl git build-essential && \
    rm -rf /var/lib/apt/lists/*

ARG IYI_VERSION=0.20.1
RUN curl -fsSL https://raw.githubusercontent.com/iyilang/iyi/v${IYI_VERSION}/install.sh | \
    IYI_PREFIX=/opt/iyi IYI_VERSION=${IYI_VERSION} sh
ENV PATH=/opt/iyi/bin:$PATH

WORKDIR /app
# iyi.sum pins iyi-web's checksum; the build fetches it at that version.
COPY iyi.mod iyi.sum app.iyi ./
RUN iyi build --release app.iyi -o server

FROM debian:stable-slim
COPY --from=build /app/server /server
ENV IYI_WEB_ENV=production
EXPOSE 8080
CMD ["/server"]
