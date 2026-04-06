FROM alpine:3.21
RUN apk add --no-cache nghttp2
ENTRYPOINT ["h2load"]
