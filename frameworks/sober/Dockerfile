# The sober compiler is a single static ELF (the standard library is built in), taken from the release tarball.
FROM alpine:3.20 AS build
ARG SOBER_VERSION=0.6.0
RUN apk add --no-cache curl tar
RUN curl -fsSL "https://github.com/sober-lang/sober/releases/download/v${SOBER_VERSION}/sober-v${SOBER_VERSION}-x86_64-linux.tar.gz" | tar -xz -C /opt
WORKDIR /app
COPY main.sober ./
RUN /opt/sober-v${SOBER_VERSION}-x86_64-linux/sober build main.sober -o server

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
