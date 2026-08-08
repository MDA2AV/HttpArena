#pragma once

#include <cstddef>
#include <functional>
#include <memory>
#include <string>

#include <folly/SocketAddress.h>

namespace proxygen {
class HTTPMessage;
class HTTPTransactionHandler;
} // namespace proxygen

namespace httparena {

class ArenaHQServer final {
public:
  using HandlerProvider = std::function<proxygen::HTTPTransactionHandler *(
      proxygen::HTTPMessage *)>;

  ArenaHQServer(const std::string &certificatePath,
                const std::string &privateKeyPath, size_t ioThreads,
                HandlerProvider handlerProvider);
  ~ArenaHQServer();

  ArenaHQServer(const ArenaHQServer &) = delete;
  ArenaHQServer &operator=(const ArenaHQServer &) = delete;

  void start(const folly::SocketAddress &address);
  void stop();

private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace httparena
