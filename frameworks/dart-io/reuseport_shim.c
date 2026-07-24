#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <sys/socket.h>

typedef int (*bind_fn)(int, const struct sockaddr *, socklen_t);

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
  static bind_fn real_bind = (bind_fn)0;
  if (!real_bind) real_bind = (bind_fn)dlsym(RTLD_NEXT, "bind");

  int type = 0;
  int opt = 1;
  socklen_t tlen = sizeof(type);
  getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &type, &tlen);
  if (type == SOCK_STREAM) {
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
  }
  return real_bind(sockfd, addr, addrlen);
}
