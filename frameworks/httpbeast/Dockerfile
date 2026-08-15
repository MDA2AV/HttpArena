FROM nimlang/nim:2.2.4 AS build

WORKDIR /app
# httpbeast is the server under test. zippy is the gzip codec for json-comp:
# httpbeast ships no compression, so the entry brings its own.
RUN nimble install -y httpbeast@0.4.2 zippy@0.10.19

COPY main.nim .
RUN nim c -d:release --mm:orc --threads:on --opt:speed -o:/app/server main.nim

# nimlang/nim:2.2.4 is Debian trixie and the binary links nothing but glibc,
# so the runtime image is the same distro with no compiler in it.
FROM debian:trixie-slim
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
