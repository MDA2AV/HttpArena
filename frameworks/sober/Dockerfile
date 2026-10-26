# The sober toolchain is pulled as an image (built by the release CI from the release tarball,
# sha256-checked - alpine with the single static ELF compiler on PATH). A registry pull only:
# nothing is downloaded from github.com at docker-build time.
FROM ghcr.io/sober-lang/sober:0.6.4 AS build
WORKDIR /app
COPY main.sober ./
RUN sober build main.sober -o server

# Runtime notes (the HttpArena harness already runs every entry this way):
#   - io_uring is blocked by Docker's default seccomp profile; run with --security-opt seccomp=unconfined.
#     Where it stays blocked (default seccomp, gVisor), the server falls back to epoll automatically.
#   - Each worker owns an io_uring ring; on kernels before 5.12 the ring memory counts against RLIMIT_MEMLOCK
#     (--ulimit memlock=-1:-1).
#   - One fd per connection: raise RLIMIT_NOFILE (--ulimit nofile=1048576:1048576).
FROM scratch
COPY --from=build /app/server /server
EXPOSE 8080 8081
CMD ["/server"]
