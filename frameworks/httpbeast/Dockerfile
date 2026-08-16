FROM nimlang/nim:2.2.4 AS build

WORKDIR /app
# zippy is the gzip codec for json-comp: httpbeast ships no compression, so
# the entry brings its own.
RUN nimble install -y zippy@0.10.19

# httpbeast 0.4.2 is the server under test, pinned to the commit nimble
# resolves for that version (there is no v0.4.2 tag upstream). It is cloned
# instead of nimble-installed because a patch is applied first: upstream reads
# a request body by Content-Length only, so a chunked request is handed to the
# handler before its body arrived and with the header end position clobbered.
# httpbeast-chunked.patch makes the read loop wait for the zero size last
# chunk and keep the header end stable; the raw chunked bytes are then decoded
# by hand in main.nim.
RUN git clone https://github.com/dom96/httpbeast.git /httpbeast \
 && git -C /httpbeast checkout 75008aaba497479df4023d52880086deae6385e3
COPY httpbeast-chunked.patch /httpbeast/
RUN git -C /httpbeast apply httpbeast-chunked.patch

COPY main.nim .
RUN nim c -d:release --mm:orc --threads:on --opt:speed --path:/httpbeast/src -o:/app/server main.nim

# nimlang/nim:2.2.4 is Debian trixie and the binary links nothing but glibc,
# so the runtime image is the same distro with no compiler in it.
FROM debian:trixie-slim
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
