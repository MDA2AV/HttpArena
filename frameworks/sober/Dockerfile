# The sober toolchain is pulled as an image (built by the release CI from the release tarball,
# sha256-checked - alpine with the single static ELF compiler on PATH). A registry pull only:
# nothing is downloaded from github.com at docker-build time.
FROM ghcr.io/sober-lang/sober:0.7.7 AS build
WORKDIR /app
COPY main.sober main.prof ./
# main.prof is the hot-code profile of this server (written by scripts/profgen.sh of the sober repository from
# callgrind runs). It only changes the order in which code blocks are laid out: cold blocks go after the hot code
# of each function. A profile line whose fingerprint does not match the code is ignored.
RUN sober build main.sober --profile=main.prof -o server

# Runtime notes (the HttpArena harness already runs every entry this way):
#   - io_uring is blocked by Docker's default seccomp profile; run with --security-opt seccomp=unconfined.
#     Where it stays blocked (default seccomp, gVisor), the server falls back to epoll automatically.
#   - Each worker owns an io_uring ring; on kernels before 5.12 the ring memory counts against RLIMIT_MEMLOCK
#     (--ulimit memlock=-1:-1).
#   - One fd per connection: raise RLIMIT_NOFILE (--ulimit nofile=1048576:1048576).
FROM scratch
COPY --from=build /app/server /server
# 8080 = HTTP/1.1, 8081 = HTTP/1.1 over TLS 1.3 (when /certs can be read), 8082 = HTTP/2 with prior knowledge (h2c)
EXPOSE 8080 8081 8082
CMD ["/server"]
