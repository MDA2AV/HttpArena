FROM nimlang/nim:2.0.14-alpine AS build
WORKDIR /app
COPY src/ ./
RUN nimble install -y prologue zippy
RUN nim c -d:release -d:danger --opt:speed --threads:on -o:server server.nim

FROM alpine:3.19
RUN apk add --no-cache libgcc
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
