#include "ArenaCommon.h"
#include "ArenaWebSocket.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <deque>
#include <future>
#include <iostream>
#include <limits>
#include <list>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <folly/ScopeGuard.h>
#include <folly/dynamic.h>
#include <folly/init/Init.h>
#include <folly/io/IOBuf.h>
#include <folly/io/async/AsyncServerSocket.h>
#include <folly/json.h>
#include <folly/portability/GFlags.h>
#include <folly/system/HardwareConcurrency.h>
#include <proxygen/lib/http/HTTPMessage.h>
#include <proxygen/lib/http/coro/HTTPCoroSession.h>
#include <proxygen/lib/http/coro/HTTPFixedSource.h>
#include <proxygen/lib/http/coro/HTTPSourceHolder.h>
#include <proxygen/lib/http/coro/filters/CompressionFilter.h>
#include <proxygen/lib/http/coro/server/HTTPServer.h>
#include <proxygen/lib/services/AcceptorConfiguration.h>
#include <quic/QuicConstants.h>
#include <wangle/ssl/SSLContextConfig.h>

DEFINE_int32(http_port, 8080, "HTTP/1.1 and WebSocket port");
DEFINE_int32(tls_port, 8081, "HTTP/1.1 over TLS port");
DEFINE_int32(h2c_port, 8082, "HTTP/2 cleartext port");
DEFINE_int32(h2_port, 8443, "HTTP/2 over TLS port");
DEFINE_int32(h3_port, 8443, "HTTP/3 over QUIC port");
DEFINE_string(ip, "::", "Address on which to listen");
DEFINE_string(cert, "/certs/server.crt", "TLS certificate path");
DEFINE_string(key, "/certs/server.key", "TLS private-key path");
DEFINE_int32(threads, 0, "TCP I/O threads; 0 uses the available CPU count");
DEFINE_int32(h3_threads, 0, "QUIC I/O threads; 0 uses the available CPU count");

namespace {

using proxygen::HTTPMessage;
using proxygen::HTTPMethod;
using proxygen::coro::HTTPBodyEvent;
using proxygen::coro::HTTPError;
using proxygen::coro::HTTPErrorCode;
using proxygen::coro::HTTPFixedSource;
using proxygen::coro::HTTPHandler;
using proxygen::coro::HTTPHeaderEvent;
using proxygen::coro::HTTPServer;
using proxygen::coro::HTTPSessionContextPtr;
using proxygen::coro::HTTPSource;
using proxygen::coro::HTTPSourceHolder;
using proxygen::coro::TimedBaton;

using httparena::checkedAdd;
using httparena::checkedMultiply;
using httparena::contentType;
using httparena::kJsonPrefix;
using httparena::kMaxRequestBody;
using httparena::kStaticPrefix;
using httparena::loadDataset;
using httparena::parseInteger;
using httparena::queryValue;
using httparena::ContentEncoding;
using httparena::StaticAssets;
using httparena::validWebSocketKey;

HTTPFixedSource *makeResponse(uint16_t status,
                              std::string_view contentTypeValue,
                              std::unique_ptr<folly::IOBuf> body) {
  auto *response = HTTPFixedSource::makeFixedResponse(status, std::move(body));
  response->msg_->getHeaders().set(proxygen::HTTP_HEADER_CONTENT_TYPE,
                                   contentTypeValue);
  return response;
}

HTTPFixedSource *makeResponse(uint16_t status,
                              std::string_view contentTypeValue,
                              std::string_view body) {
  return makeResponse(status, contentTypeValue, folly::IOBuf::copyBuffer(body));
}

HTTPFixedSource *makeTextResponse(uint16_t status, std::string_view body) {
  return makeResponse(status, "text/plain", body);
}

// Renders an integer response body without the std::to_string allocation.
HTTPFixedSource *makeIntResponse(uint16_t status, int64_t value) {
  std::array<char, 24> digits;
  const auto end =
      std::to_chars(digits.data(), digits.data() + digits.size(), value);
  return makeTextResponse(
      status, std::string_view(digits.data(),
                               static_cast<size_t>(end.ptr - digits.data())));
}

folly::coro::Task<HTTPBodyEvent>
readBodyEventNoSuspend(HTTPSourceHolder &source,
                       uint32_t max = std::numeric_limits<uint32_t>::max()) {
  while (true) {
    auto event = co_await co_awaitTry(source.readBodyEvent(max));
    if (event.hasException()) {
      co_yield folly::coro::co_error(std::move(event.exception()));
    }
    if (event->eventType == HTTPBodyEvent::SUSPEND) {
      const auto status = co_await std::move(event->event.resume);
      if (status == TimedBaton::Status::cancelled) {
        co_yield folly::coro::co_error(
            HTTPError(HTTPErrorCode::CORO_CANCELLED, "request read cancelled"));
      }
      continue;
    }
    co_return std::move(*event);
  }
}

struct RequestBody {
  bool readOk{true};
  bool captureOk{true};
  size_t size{0};
  std::string captured;
};

folly::coro::Task<RequestBody> readRequestBody(HTTPSourceHolder &source,
                                               bool eom, size_t captureLimit) {
  RequestBody result;
  while (!eom) {
    auto eventTry = co_await co_awaitTry(readBodyEventNoSuspend(source));
    if (eventTry.hasException()) {
      result.readOk = false;
      co_return result;
    }
    auto event = std::move(*eventTry);
    eom = event.eom;
    if (event.eventType == HTTPBodyEvent::PADDING) {
      continue;
    }
    if (event.eventType != HTTPBodyEvent::BODY) {
      result.readOk = false;
      co_return result;
    }

    const size_t bytes = event.event.body.chainLength();
    if (bytes > std::numeric_limits<size_t>::max() - result.size) {
      result.readOk = false;
      co_return result;
    }
    result.size += bytes;
    if (captureLimit == 0 || !result.captureOk) {
      continue;
    }
    if (result.captured.size() > captureLimit ||
        bytes > captureLimit - result.captured.size()) {
      result.captureOk = false;
      continue;
    }
    auto body = event.event.body.move();
    if (body) {
      const auto range = body->coalesce();
      result.captured.append(reinterpret_cast<const char *>(range.data()),
                             range.size());
    }
  }
  co_return result;
}

// Long-lived response source for an upgraded WebSocket connection: raw frames
// arrive as BODY events on the request source, and the echoed frames leave as
// BODY events on this one. Framing is the shared codec in ArenaWebSocket.h, so
// a read carrying N pipelined frames produces one egress event.
class WebSocketSource final : public HTTPSource {
public:
  explicit WebSocketSource(HTTPSourceHolder request)
      : request_(std::move(request)) {
    setHeapAllocated();
  }

  folly::coro::Task<HTTPHeaderEvent> readHeaderEvent() override {
    auto response = std::make_unique<HTTPMessage>();
    response->setHTTPVersion(1, 1);
    response->setStatusCode(200);
    response->setStatusMessage("OK");
    response->setEgressWebsocketUpgrade();
    HTTPHeaderEvent event(std::move(response), false);
    auto guard = folly::makeGuard(lifetime(event));
    co_return event;
  }

  folly::coro::Task<HTTPBodyEvent>
  readBodyEvent(uint32_t max = std::numeric_limits<uint32_t>::max()) override {
    while (!websocket_.hasEgress() && !eom_) {
      auto inputTry = co_await co_awaitTry(readBodyEventNoSuspend(request_));
      if (inputTry.hasException()) {
        auto error = proxygen::coro::getHTTPError(inputTry);
        auto guard = folly::makeGuard([this] {
          if (heapAllocated_) {
            delete this;
          }
        });
        co_yield folly::coro::co_error(std::move(error));
      }

      auto input = std::move(*inputTry);
      if (input.eventType == HTTPBodyEvent::BODY) {
        websocket_.onIngress(input.event.body.move());
      }
      if (input.eom || websocket_.finished()) {
        eom_ = true;
      }
    }

    auto body = websocket_.takeEgress(std::max<size_t>(1, max));
    // Only signal EOM once everything the codec produced has been handed over.
    const bool eom = eom_ && !websocket_.hasEgress();
    HTTPBodyEvent event(std::move(body), eom);
    auto guard = folly::makeGuard(lifetime(event));
    co_return event;
  }

  void stopReading(folly::Optional<const HTTPErrorCode> error =
                       folly::none) noexcept override {
    if (request_) {
      request_.stopReading(error);
    }
    if (heapAllocated_) {
      delete this;
    }
  }

private:
  HTTPSourceHolder request_;
  httparena::WebSocketEcho websocket_;
  bool eom_{false};
};


// Only `json-comp` asks for a compressed response, and it is the one profile
// scored on compression ratio rather than raw rps. `static` sends
// `Accept-Encoding: br;q=1, gzip;q=0.8` too, so listing the static content
// types here would mean gzipping 8-200 KB per CSS/JS/HTML request on the event
// base for no scoring benefit (compression is explicitly optional for
// `static`).
proxygen::CompressionFilterUtils::FactoryOptions compressionOptions() {
  proxygen::CompressionFilterUtils::FactoryOptions options;
  options.compressibleContentTypes =
      std::make_shared<const std::set<std::string>>(
          std::set<std::string>{"application/json"});
  // FactoryOptions defaults to 4; HTTPServerOptions (and so the classic entry)
  // defaults to Z_DEFAULT_COMPRESSION. json-comp is scored on
  // (minBpr/myBpr)^2, so the weaker ratio cost the coro entry ~17% of that
  // profile's score for no throughput gain worth having.
  options.zlibCompressionLevel = -1;
  return options;
}

class ArenaCoroHandler final : public HTTPHandler {
public:
  explicit ArenaCoroHandler(std::shared_ptr<const folly::dynamic> dataset)
      : dataset_(std::move(dataset)), items_(*dataset_) {
    assets_.load();
  }

  folly::coro::Task<HTTPSourceHolder>
  handleRequest(folly::EventBase * /*eventBase*/,
                HTTPSessionContextPtr /*session*/,
                HTTPSourceHolder requestSource) override {
    auto headerTry = co_await co_awaitTry(requestSource.readHeaderEvent());
    if (headerTry.hasException()) {
      co_return makeTextResponse(400, "bad request");
    }
    auto header = std::move(*headerTry);
    auto request = std::move(header.headers);
    const bool requestEom = header.eom;
    const auto method = request->getMethod().value_or(HTTPMethod::GET);
    const auto pathPiece = request->getPathAsStringPiece();
    const std::string_view path(pathPiece.data(), pathPiece.size());
    const auto queryPiece = request->getQueryStringAsStringPiece();
    const std::string_view query(queryPiece.data(), queryPiece.size());

    if (path == "/ws") {
      const auto &headers = request->getHeaders();
      const auto &key = headers.getSingleOrEmpty("Sec-WebSocket-Key");
      const auto &version = headers.getSingleOrEmpty("Sec-WebSocket-Version");
      if (method != HTTPMethod::GET || !request->isIngressWebsocketUpgrade() ||
          !validWebSocketKey(std::string_view(key.data(), key.size())) ||
          version != "13") {
        auto *response = makeTextResponse(426, "WebSocket upgrade required");
        response->msg_->getHeaders().set("Sec-WebSocket-Version", "13");
        co_return response;
      }
      co_return new WebSocketSource(std::move(requestSource));
    }

    if (path == "/baseline11" || path == "/baseline2") {
      const bool allowPost = path == "/baseline11";
      if (method != HTTPMethod::GET &&
          (!allowPost || method != HTTPMethod::POST)) {
        co_return makeTextResponse(405, "method not allowed");
      }
      int64_t a = 0;
      int64_t b = 0;
      const auto aText = queryValue(query, "a");
      const auto bText = queryValue(query, "b");
      if (!aText || !bText || !parseInteger(*aText, a) ||
          !parseInteger(*bText, b)) {
        co_return makeTextResponse(400, "invalid integer");
      }
      int64_t sum = 0;
      if (!checkedAdd(a, b, sum)) {
        co_return makeTextResponse(400, "integer overflow");
      }
      if (method == HTTPMethod::POST) {
        auto body = co_await readRequestBody(requestSource, requestEom,
                                             kMaxRequestBody);
        int64_t bodyValue = 0;
        if (!body.readOk || !body.captureOk ||
            !parseInteger(body.captured, bodyValue) ||
            !checkedAdd(sum, bodyValue, sum)) {
          co_return makeTextResponse(400, "invalid integer");
        }
      }
      co_return makeIntResponse(200, sum);
    }

    if (path == "/pipeline") {
      if (method != HTTPMethod::GET) {
        co_return makeTextResponse(405, "method not allowed");
      }
      co_return makeTextResponse(200, "ok");
    }

    if (path.starts_with(kJsonPrefix)) {
      if (method != HTTPMethod::GET) {
        co_return makeTextResponse(405, "method not allowed");
      }
      const std::string_view countText(path.data() + kJsonPrefix.size(),
                                       path.size() - kJsonPrefix.size());
      int64_t count = 0;
      int64_t multiplier = 1;
      const auto multiplierText = queryValue(query, "m");
      if (!parseInteger(countText, count) || count < 1 || count > 50 ||
          (multiplierText && !parseInteger(*multiplierText, multiplier))) {
        co_return makeTextResponse(400, "invalid JSON parameters");
      }
      if (static_cast<size_t>(count) > items_.size()) {
        co_return makeTextResponse(400, "invalid JSON parameters");
      }

      try {
        folly::dynamic items = folly::dynamic::array;
        items.reserve(static_cast<size_t>(count));
        for (int64_t index = 0; index < count; ++index) {
          folly::dynamic item = items_[static_cast<size_t>(index)];
          int64_t subtotal = 0;
          int64_t total = 0;
          if (!checkedMultiply(item["price"].asInt(), item["quantity"].asInt(),
                               subtotal) ||
              !checkedMultiply(subtotal, multiplier, total)) {
            co_return makeTextResponse(400, "integer overflow");
          }
          item["total"] = total;
          items.push_back(std::move(item));
        }
        folly::dynamic response = folly::dynamic::object;
        response["items"] = std::move(items);
        response["count"] = count;
        co_return maybeCompress(
            makeResponse(200, "application/json",
                         folly::IOBuf::fromString(folly::toJson(response))),
            *request);
      } catch (const std::exception &) {
        co_return makeTextResponse(500, "JSON serialization failed");
      }
    }

    if (path == "/upload") {
      if (method != HTTPMethod::POST) {
        co_return makeTextResponse(405, "method not allowed");
      }
      auto body = co_await readRequestBody(requestSource, requestEom, 0);
      if (!body.readOk) {
        co_return makeTextResponse(400, "upload failed");
      }
      co_return makeIntResponse(200, static_cast<int64_t>(body.size));
    }

    if (path.starts_with(kStaticPrefix)) {
      if (method != HTTPMethod::GET) {
        co_return makeTextResponse(405, "method not allowed");
      }
      // Exact lookup in the preloaded table, so traversal is impossible and a
      // miss is just a 404.
      const auto *asset = assets_.find(path.substr(kStaticPrefix.size()));
      if (asset == nullptr) {
        co_return makeTextResponse(404, "not found");
      }
      const auto &accept = request->getHeaders().getSingleOrEmpty(
          proxygen::HTTP_HEADER_ACCEPT_ENCODING);
      const auto [body, encoding] =
          asset->select(std::string_view(accept.data(), accept.size()));
      // Non-owning view of the table, which outlives every request.
      auto *response =
          makeResponse(200, asset->contentType,
                       folly::IOBuf::wrapBuffer(body->data(), body->size()));
      if (encoding != ContentEncoding::Identity) {
        auto &headers = response->msg_->getHeaders();
        headers.set(proxygen::HTTP_HEADER_CONTENT_ENCODING,
                    httparena::encodingToken(encoding));
        headers.set(proxygen::HTTP_HEADER_VARY, "Accept-Encoding");
      }
      co_return response;
    }

    co_return makeTextResponse(404, "not found");
  }

private:
  // Wraps `response` in proxygen's coro CompressionFilter when this client
  // actually negotiated an encoding we support.
  //
  // The alternative is registering ServerCompressionFilterFactory on
  // HTTPServer::Config, but HTTPFilterFactoryHandler calls makeFilters()
  // before the request headers have been read, so the factory cannot be
  // conditional: every request — `baseline` included, where nothing is
  // compressible — pays a SharedCtx, a VisitorFilter with a capturing lambda,
  // a CompressionFilter and the surrounding coroutine frame. That measured at
  // ~10% of baseline throughput. Attaching the filter here instead keeps the
  // cost on the responses that are actually compressed. (The classic
  // HTTPServer path has no such problem: CompressionFilterFactory::onRequest
  // sees the request and returns the handler unwrapped when there is nothing
  // to do.)
  HTTPSourceHolder maybeCompress(HTTPFixedSource *response,
                                 const HTTPMessage &request) {
    auto params = std::make_shared<
        folly::Optional<proxygen::CompressionFilterUtils::FilterParams>>(
        proxygen::CompressionFilterUtils::getFilterParams(request,
                                                          compression_));
    if (!params->hasValue()) {
      return response;
    }
    auto *filter =
        new proxygen::coro::CompressionFilter(response, std::move(params));
    filter->setHeapAllocated();
    return filter;
  }

  std::shared_ptr<const folly::dynamic> dataset_;
  // The handler is shared by every session and outlives all of them, so the
  // hot path can dereference the dataset once here instead of per request.
  const folly::dynamic &items_;
  const proxygen::CompressionFilterUtils::FactoryOptions compression_{
      compressionOptions()};
  StaticAssets assets_;
};

constexpr uint32_t kH2StreamWindow = 1U << 20;
constexpr size_t kH2ConnectionWindow = 10U << 20;
constexpr uint32_t kMaxConcurrentStreams = 1024;

HTTPServer::SessionConfig makeSessionConfig() {
  HTTPServer::SessionConfig session;
  session.settings = {
      {proxygen::SettingsId::MAX_HEADER_LIST_SIZE, 32 * 1024},
      {proxygen::SettingsId::HEADER_TABLE_SIZE, 4096},
      {proxygen::SettingsId::MAX_FRAME_SIZE, 16384},
      {proxygen::SettingsId::MAX_CONCURRENT_STREAMS, kMaxConcurrentStreams},
      {proxygen::SettingsId::INITIAL_WINDOW_SIZE, kH2StreamWindow}};
  session.streamFlowControl = kH2StreamWindow;
  session.connFlowControl = kH2ConnectionWindow;
  session.streamReadTimeout = std::chrono::seconds(60);
  session.connIdleTimeout = std::chrono::seconds(60);
  return session;
}


wangle::SSLContextConfig tlsConfig(std::list<std::string> protocols) {
  auto config = HTTPServer::getDefaultTLSConfig();
  config.setCertificate(FLAGS_cert, FLAGS_key, "");
  config.setNextProtocols(protocols);
  return config;
}

std::shared_ptr<proxygen::AcceptorConfiguration>
acceptorConfig(const HTTPServer::Config &serverConfig,
               std::string plaintextProtocol,
               std::list<std::string> tlsProtocols = {}) {
  auto config = std::make_shared<proxygen::AcceptorConfiguration>();
  *static_cast<wangle::ServerSocketConfig *>(config.get()) =
      serverConfig.socketConfig;
  config->sslContextConfigs.clear();
  if (!tlsProtocols.empty()) {
    config->sslContextConfigs.push_back(tlsConfig(std::move(tlsProtocols)));
  }
  config->egressSettings = serverConfig.sessionConfig.settings;
  config->transactionIdleTimeout = serverConfig.sessionConfig.streamReadTimeout;
  config->initialReceiveWindow = kH2StreamWindow;
  config->receiveStreamWindowSize = kH2StreamWindow;
  config->receiveSessionWindowSize = kH2ConnectionWindow;
  config->maxConcurrentIncomingStreams = kMaxConcurrentStreams;
  config->plaintextProtocol = std::move(plaintextProtocol);
  config->forceHTTP1_0_to_1_1 = true;
  config->connectionIdleTimeout = serverConfig.sessionConfig.connIdleTimeout;
  config->readBufNewAllocSize = serverConfig.sessionConfig.readBufNewAllocSize;
  return config;
}

HTTPServer::SocketAcceptorConfigFactoryFn tcpSocketFactory() {
  return [](folly::EventBase &eventBase,
            const HTTPServer::Config &serverConfig) {
    std::vector<HTTPServer::SocketAcceptorConfig> listeners;
    const auto addListener = [&](uint16_t port, std::string protocol,
                                 std::list<std::string> tlsProtocols = {}) {
      folly::AsyncServerSocket::UniquePtr socket(
          new folly::AsyncServerSocket(&eventBase));
      socket->bind(folly::SocketAddress(FLAGS_ip, port, true));
      socket->listen(serverConfig.socketConfig.acceptBacklog);
      listeners.emplace_back(std::move(socket),
                             acceptorConfig(serverConfig, std::move(protocol),
                                            std::move(tlsProtocols)));
    };

    addListener(static_cast<uint16_t>(FLAGS_http_port), "http/1.1");
    addListener(static_cast<uint16_t>(FLAGS_tls_port), "http/1.1",
                {"http/1.1"});
    addListener(static_cast<uint16_t>(FLAGS_h2c_port), "h2c");
    addListener(static_cast<uint16_t>(FLAGS_h2_port), "", {"h2"});
    return listeners;
  };
}

HTTPServer::Config tcpConfig(size_t threads) {
  HTTPServer::Config config;
  config.numIOThreads = threads;
  config.shutdownOnSignals = {SIGINT, SIGTERM};
  config.sessionConfig = makeSessionConfig();
  return config;
}

HTTPServer::Config quicConfig(size_t threads) {
  HTTPServer::Config config;
  config.socketConfig.bindAddress =
      folly::SocketAddress(FLAGS_ip, FLAGS_h3_port, true);
  config.socketConfig.sslContextConfigs.push_back(tlsConfig({"h3"}));
  config.numIOThreads = threads;
  config.shutdownOnSignals = {};
  config.sessionConfig = makeSessionConfig();
  config.quicConfig = HTTPServer::QuicConfig();
  config.quicConfig->supportedAlpns = {"h3"};
  auto &transport = config.quicConfig->transportSettings;
  transport.maxNumPTOs = 1000;
  transport.maxCwndInMss = quic::kLargeMaxCwndInMss;
  transport.batchingMode = quic::QuicBatchingMode::BATCHING_MODE_GSO;
  transport.maxBatchSize = 48;
  transport.dataPathType = quic::DataPathType::ContinuousMemory;
  transport.writeConnectionDataPacketsLimit = 48;
  return config;
}

} // namespace

int main(int argc, char *argv[]) {
  const folly::Init init(&argc, &argv, true);

  try {
    auto dataset = loadDataset();
    const size_t threads =
        FLAGS_threads <= 0 ? static_cast<size_t>(folly::available_concurrency())
                           : static_cast<size_t>(FLAGS_threads);
    const size_t h3Threads =
        FLAGS_h3_threads <= 0
            ? static_cast<size_t>(folly::available_concurrency())
            : static_cast<size_t>(FLAGS_h3_threads);
    auto handler = std::make_shared<ArenaCoroHandler>(std::move(dataset));

    HTTPServer tcpServer(tcpConfig(threads), handler, tcpSocketFactory());
    HTTPServer h3Server(quicConfig(h3Threads), std::move(handler));

    std::promise<void> h3Ready;
    auto h3ReadyFuture = h3Ready.get_future();
    std::thread h3Thread([&] {
      try {
        h3Server.start([&] { h3Ready.set_value(); });
      } catch (...) {
        try {
          h3Ready.set_exception(std::current_exception());
        } catch (const std::future_error &) {
        }
      }
    });

    try {
      h3ReadyFuture.get();
    } catch (...) {
      h3Thread.join();
      throw;
    }

    try {
      tcpServer.start();
    } catch (...) {
      h3Server.forceStop();
      h3Thread.join();
      throw;
    }

    h3Server.forceStop();
    h3Thread.join();
  } catch (const std::exception &error) {
    std::cerr << "failed to start Proxygen coroutine HttpArena server: "
              << error.what() << '\n';
    return 1;
  }
  return 0;
}
