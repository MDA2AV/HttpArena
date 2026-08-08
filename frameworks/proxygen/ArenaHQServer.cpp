#include "ArenaHQServer.h"

#include <utility>

#include <proxygen/httpserver/samples/hq/FizzContext.h>
#include <proxygen/httpserver/samples/hq/HQServer.h>
#include <quic/QuicConstants.h>

namespace {

quic::samples::HQServerParams makeHQParams(size_t ioThreads) {
  quic::samples::HQServerParams params;
  params.serverThreads = ioThreads;
  params.transportSettings.maxNumPTOs = 1000;
  params.transportSettings.maxCwndInMss = quic::kLargeMaxCwndInMss;
  params.transportSettings.batchingMode =
      quic::QuicBatchingMode::BATCHING_MODE_GSO;
  params.transportSettings.maxBatchSize = 48;
  params.transportSettings.dataPathType = quic::DataPathType::ContinuousMemory;
  params.transportSettings.writeConnectionDataPacketsLimit = 48;
  return params;
}

} // namespace

namespace httparena {

class ArenaHQServer::Impl final {
public:
  Impl(const std::string &certificatePath, const std::string &privateKeyPath,
       size_t ioThreads, HandlerProvider handlerProvider)
      : server_(makeHQParams(ioThreads), std::move(handlerProvider), nullptr,
                quic::samples::createFizzServerContext(
                    quic::samples::kDefaultSupportedAlpns,
                    fizz::server::ClientAuthMode::None, certificatePath,
                    privateKeyPath)) {}

  ~Impl() { stop(); }

  void start(const folly::SocketAddress &address) {
    started_ = true;
    server_.start(address);
    server_.getAddress();
  }

  void stop() {
    if (started_) {
      server_.stop();
      started_ = false;
    }
  }

private:
  quic::samples::HQServer server_;
  bool started_{false};
};

ArenaHQServer::ArenaHQServer(const std::string &certificatePath,
                             const std::string &privateKeyPath,
                             size_t ioThreads, HandlerProvider handlerProvider)
    : impl_(std::make_unique<Impl>(certificatePath, privateKeyPath, ioThreads,
                                   std::move(handlerProvider))) {}

ArenaHQServer::~ArenaHQServer() = default;

void ArenaHQServer::start(const folly::SocketAddress &address) {
  impl_->start(address);
}

void ArenaHQServer::stop() { impl_->stop(); }

} // namespace httparena
