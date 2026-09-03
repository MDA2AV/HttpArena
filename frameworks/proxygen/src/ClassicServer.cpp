#include "ArenaCommon.h"
#include "ArenaHQServer.h"
#include "ArenaWebSocket.h"

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <list>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <folly/dynamic.h>
#include <folly/init/Init.h>
#include <folly/io/IOBuf.h>
#include <folly/json.h>
#include <folly/portability/GFlags.h>
#include <folly/system/HardwareConcurrency.h>
#include <proxygen/httpserver/HTTPServer.h>
#include <proxygen/httpserver/RequestHandlerAdaptor.h>
#include <proxygen/httpserver/RequestHandlerFactory.h>
#include <proxygen/httpserver/ResponseBuilder.h>
#include <wangle/ssl/SSLContextConfig.h>

using folly::SocketAddress;
using proxygen::HTTPMessage;
using proxygen::HTTPMethod;
using proxygen::HTTPServer;
using proxygen::ProxygenError;
using proxygen::RequestHandler;
using proxygen::RequestHandlerChain;
using proxygen::RequestHandlerFactory;
using proxygen::ResponseBuilder;
using proxygen::UpgradeProtocol;

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

class ArenaHandler final : public RequestHandler {
public:
  // The dataset is owned by the handler factory, which outlives every handler
  // it creates. Taking a reference rather than a shared_ptr copy keeps two
  // atomic refcount updates on a globally shared cache line off the per-request
  // path — one handler is allocated per request.
  ArenaHandler(const folly::dynamic &dataset, const StaticAssets &assets)
      : dataset_(dataset), assets_(assets) {}

  void onRequest(std::unique_ptr<HTTPMessage> request) noexcept override {
    const auto path = request->getPathAsStringPiece();
    const auto method = request->getMethod();

    if (path == "/ws") {
      route_ = Route::WebSocket;
      const auto &headers = request->getHeaders();
      const auto &key = headers.getSingleOrEmpty("Sec-WebSocket-Key");
      const auto &version = headers.getSingleOrEmpty("Sec-WebSocket-Version");
      if (!method || *method != HTTPMethod::GET ||
          !request->isIngressWebsocketUpgrade() ||
          !validWebSocketKey(std::string_view(key.data(), key.size())) ||
          version != "13") {
        ResponseBuilder(downstream_)
            .status(426, "Upgrade Required")
            .header("Content-Type", "text/plain")
            .header("Sec-WebSocket-Version", "13")
            .body("WebSocket upgrade required")
            .sendWithEOM();
        responseFinished_ = true;
        return;
      }

      ResponseBuilder(downstream_)
          .status(101, "Switching Protocols")
          .setEgressWebsocketHeaders()
          .send();
      websocketAccepted_ = true;
      return;
    }

    method_ = method.value_or(HTTPMethod::GET);
    const std::string_view query(request->getQueryStringAsStringPiece().data(),
                                 request->getQueryStringAsStringPiece().size());

    if (path == "/baseline11" || path == "/baseline2") {
      route_ = path == "/baseline11" ? Route::Baseline : Route::BaselineH2;
      const auto a = queryValue(query, "a");
      const auto b = queryValue(query, "b");
      queryValid_ = a && b && parseInteger(*a, a_) && parseInteger(*b, b_);
      return;
    }
    if (path.startsWith(kJsonPrefix)) {
      route_ = Route::Json;
      const std::string_view countText(path.data() + kJsonPrefix.size(),
                                       path.size() - kJsonPrefix.size());
      int64_t count = 0;
      const auto multiplierText = queryValue(query, "m");
      const bool multiplierValid =
          !multiplierText ? (multiplier_ = 1, true)
                          : parseInteger(*multiplierText, multiplier_);
      jsonValid_ = parseInteger(countText, count) && count >= 1 &&
                   count <= 50 && multiplierValid;
      if (jsonValid_) {
        jsonCount_ = static_cast<size_t>(count);
      }
      return;
    }
    if (path == "/upload") {
      route_ = Route::Upload;
      return;
    }
    if (path.startsWith(kStaticPrefix)) {
      route_ = Route::Static;
      staticName_.assign(path.data() + kStaticPrefix.size(),
                         path.size() - kStaticPrefix.size());
      const auto &encoding =
          request->getHeaders().getSingleOrEmpty(
              proxygen::HTTP_HEADER_ACCEPT_ENCODING);
      acceptEncoding_.assign(encoding.data(), encoding.size());
      return;
    }
    if (path == "/pipeline") {
      route_ = Route::Pipeline;
      return;
    }
    route_ = Route::NotFound;
  }

  void onBody(std::unique_ptr<folly::IOBuf> body) noexcept override {
    if (!body || responseFinished_) {
      return;
    }
    if (route_ == Route::Upload) {
      const size_t bytes = body->computeChainDataLength();
      if (bytes > std::numeric_limits<size_t>::max() - uploadBytes_) {
        uploadValid_ = false;
      } else {
        uploadBytes_ += bytes;
      }
      return;
    }
    if (route_ == Route::WebSocket && websocketActive_) {
      websocket_.onIngress(std::move(body));
      flushWebSocket();
      return;
    }
    if (route_ != Route::Baseline) {
      return;
    }
    auto bytes = body->coalesce();
    if (requestBody_.size() + bytes.size() > kMaxRequestBody) {
      bodyValid_ = false;
      return;
    }
    requestBody_.append(reinterpret_cast<const char *>(bytes.data()),
                        bytes.size());
  }

  void onUpgrade(UpgradeProtocol /*protocol*/) noexcept override {
    if (route_ != Route::WebSocket || !websocketAccepted_) {
      downstream_->sendAbort();
      return;
    }
    websocketActive_ = true;
  }

  void onEOM() noexcept override {
    if (responseFinished_) {
      return;
    }
    switch (route_) {
    case Route::WebSocket:
      responseFinished_ = true;
      downstream_->sendEOM();
      return;
    case Route::NotFound:
      sendText(404, "Not Found", "not found");
      return;
    case Route::Pipeline:
      if (method_ != HTTPMethod::GET) {
        sendText(405, "Method Not Allowed", "method not allowed");
      } else {
        sendText(200, "OK", "ok");
      }
      return;
    case Route::Baseline:
      handleBaseline(true);
      return;
    case Route::BaselineH2:
      handleBaseline(false);
      return;
    case Route::Json:
      handleJson();
      return;
    case Route::Upload:
      if (method_ != HTTPMethod::POST) {
        sendText(405, "Method Not Allowed", "method not allowed");
      } else if (!uploadValid_) {
        sendText(400, "Bad Request", "upload too large");
      } else {
        std::array<char, 24> digits;
        const auto end = std::to_chars(
            digits.data(), digits.data() + digits.size(), uploadBytes_);
        sendText(200, "OK",
                 std::string_view(
                     digits.data(),
                     static_cast<size_t>(end.ptr - digits.data())));
      }
      return;
    case Route::Static:
      handleStatic();
      return;
    }
  }

  void requestComplete() noexcept override { delete this; }

  void onError(ProxygenError /*error*/) noexcept override { delete this; }

private:
  enum class Route {
    NotFound,
    Baseline,
    BaselineH2,
    Json,
    Upload,
    Static,
    Pipeline,
    WebSocket
  };

  void handleBaseline(bool allowPost) {
    if (!queryValid_ || !bodyValid_) {
      sendText(400, "Bad Request", "invalid integer");
      return;
    }
    if (method_ != HTTPMethod::GET &&
        (!allowPost || method_ != HTTPMethod::POST)) {
      sendText(405, "Method Not Allowed", "method not allowed");
      return;
    }

    int64_t sum = 0;
    if (!checkedAdd(a_, b_, sum)) {
      sendText(400, "Bad Request", "integer overflow");
      return;
    }
    if (method_ == HTTPMethod::POST) {
      int64_t bodyValue = 0;
      if (!parseInteger(requestBody_, bodyValue) ||
          !checkedAdd(sum, bodyValue, sum)) {
        sendText(400, "Bad Request", "invalid integer");
        return;
      }
    }
    std::array<char, 24> digits;
    const auto end = std::to_chars(digits.data(), digits.data() + digits.size(),
                                   sum);
    sendText(200, "OK",
             std::string_view(digits.data(),
                              static_cast<size_t>(end.ptr - digits.data())));
  }

  void handleJson() {
    if (method_ != HTTPMethod::GET) {
      sendText(405, "Method Not Allowed", "method not allowed");
      return;
    }
    if (!jsonValid_ || jsonCount_ > dataset_.size()) {
      sendText(400, "Bad Request", "invalid JSON parameters");
      return;
    }

    try {
      folly::dynamic items = folly::dynamic::array;
      items.reserve(jsonCount_);
      for (size_t index = 0; index < jsonCount_; ++index) {
        folly::dynamic item = dataset_[index];
        int64_t subtotal = 0;
        int64_t total = 0;
        if (!checkedMultiply(item["price"].asInt(), item["quantity"].asInt(),
                             subtotal) ||
            !checkedMultiply(subtotal, multiplier_, total)) {
          sendText(400, "Bad Request", "integer overflow");
          return;
        }
        item["total"] = total;
        items.push_back(std::move(item));
      }
      folly::dynamic response = folly::dynamic::object;
      response["items"] = std::move(items);
      response["count"] = static_cast<int64_t>(jsonCount_);
      // fromString takes ownership of the serialized buffer; copyBuffer would
      // memcpy up to ~30 KB per response and shows up directly in json-comp.
      sendResponse(200, "OK", "application/json",
                   folly::IOBuf::fromString(folly::toJson(response)));
    } catch (const std::exception &) {
      sendText(500, "Internal Server Error", "JSON serialization failed");
    }
  }

  void handleStatic() {
    if (method_ != HTTPMethod::GET) {
      sendText(405, "Method Not Allowed", "method not allowed");
      return;
    }
    const auto *asset = assets_.find(staticName_);
    if (asset == nullptr) {
      sendText(404, "Not Found", "not found");
      return;
    }
    const auto [body, encoding] = asset->select(acceptEncoding_);

    responseFinished_ = true;
    ResponseBuilder builder(downstream_);
    builder.status(200, "OK")
        .header(proxygen::HTTP_HEADER_CONTENT_TYPE, asset->contentType);
    if (encoding != ContentEncoding::Identity) {
      builder.header(proxygen::HTTP_HEADER_CONTENT_ENCODING,
                     httparena::encodingToken(encoding));
      // The same URL yields different bytes per Accept-Encoding.
      builder.header(proxygen::HTTP_HEADER_VARY, "Accept-Encoding");
    }
    // Non-owning view of the preloaded table, which outlives every request.
    builder.body(folly::IOBuf::wrapBuffer(body->data(), body->size()))
        .sendWithEOM();
  }

  void sendResponse(uint16_t status, const char *reason, std::string_view type,
                    std::unique_ptr<folly::IOBuf> body) {
    responseFinished_ = true;
    ResponseBuilder(downstream_)
        .status(status, reason)
        .header(proxygen::HTTP_HEADER_CONTENT_TYPE, type)
        .body(std::move(body))
        .sendWithEOM();
  }

  void sendResponse(uint16_t status, const char *reason, std::string_view type,
                    std::string_view body) {
    sendResponse(status, reason, type, folly::IOBuf::copyBuffer(body));
  }

  void sendText(uint16_t status, const char *reason, std::string_view body) {
    sendResponse(status, reason, "text/plain", body);
  }

  // Drains whatever the shared RFC 6455 codec produced for this read as a
  // single egress write, then closes the stream if the codec is done.
  void flushWebSocket() {
    if (auto egress = websocket_.takeEgress()) {
      downstream_->sendBody(std::move(egress));
    }
    if (websocket_.finished() && !responseFinished_) {
      responseFinished_ = true;
      downstream_->sendEOM();
    }
  }

  Route route_{Route::NotFound};
  const folly::dynamic &dataset_;
  const StaticAssets &assets_;
  HTTPMethod method_{HTTPMethod::GET};
  int64_t a_{0};
  int64_t b_{0};
  int64_t multiplier_{1};
  size_t jsonCount_{0};
  size_t uploadBytes_{0};
  bool queryValid_{false};
  bool jsonValid_{false};
  bool uploadValid_{true};
  bool bodyValid_{true};
  bool websocketAccepted_{false};
  bool websocketActive_{false};
  bool responseFinished_{false};
  std::string requestBody_;
  std::string staticName_;
  std::string acceptEncoding_;
  httparena::WebSocketEcho websocket_;
};

class ArenaHandlerFactory final : public RequestHandlerFactory {
public:
  ArenaHandlerFactory(std::shared_ptr<const folly::dynamic> dataset,
                      const StaticAssets &assets)
      : dataset_(std::move(dataset)), assets_(assets) {}

  void onServerStart(folly::EventBase * /*eventBase*/) noexcept override {}

  void onServerStop() noexcept override {}

  RequestHandler *onRequest(RequestHandler *, HTTPMessage *) noexcept override {
    return new ArenaHandler(*dataset_, assets_);
  }

private:
  std::shared_ptr<const folly::dynamic> dataset_;
  const StaticAssets &assets_;
};

wangle::SSLContextConfig h1TlsConfig() {
  wangle::SSLContextConfig config;
  config.isDefault = true;
  config.clientVerification =
      folly::SSLContext::VerifyClientCertificate::DO_NOT_REQUEST;
  config.setCertificate(FLAGS_cert, FLAGS_key, "");
  config.setNextProtocols(std::list<std::string>{"http/1.1"});
  return config;
}

wangle::SSLContextConfig h2TlsConfig() {
  wangle::SSLContextConfig config;
  config.isDefault = true;
  config.clientVerification =
      folly::SSLContext::VerifyClientCertificate::DO_NOT_REQUEST;
  config.setCertificate(FLAGS_cert, FLAGS_key, "");
  config.setNextProtocols(std::list<std::string>{"h2"});
  return config;
}

std::vector<HTTPServer::IPConfig> listenerConfigs() {
  std::vector<HTTPServer::IPConfig> listeners;
  listeners.emplace_back(SocketAddress(FLAGS_ip, FLAGS_http_port, true),
                         HTTPServer::Protocol::HTTP);
  listeners.emplace_back(SocketAddress(FLAGS_ip, FLAGS_h2c_port, true),
                         HTTPServer::Protocol::HTTP2);

  HTTPServer::IPConfig tlsListener(
      SocketAddress(FLAGS_ip, FLAGS_tls_port, true),
      HTTPServer::Protocol::HTTP);
  tlsListener.sslConfigs.push_back(h1TlsConfig());
  listeners.push_back(std::move(tlsListener));

  HTTPServer::IPConfig h2Listener(SocketAddress(FLAGS_ip, FLAGS_h2_port, true),
                                  HTTPServer::Protocol::HTTP2);
  h2Listener.sslConfigs.push_back(h2TlsConfig());
  listeners.push_back(std::move(h2Listener));
  return listeners;
}

} // namespace

int main(int argc, char *argv[]) {
  const folly::Init init(&argc, &argv, true);

  if (FLAGS_threads <= 0) {
    FLAGS_threads = static_cast<int32_t>(folly::available_concurrency());
  }
  if (FLAGS_h3_threads <= 0) {
    FLAGS_h3_threads = static_cast<int32_t>(folly::available_concurrency());
  }
  CHECK_GT(FLAGS_threads, 0);
  CHECK_GT(FLAGS_h3_threads, 0);

  static httparena::StaticAssets assets;

  try {
    auto dataset = loadDataset();
    assets.load();

    proxygen::HTTPServerOptions options;
    options.threads = static_cast<size_t>(FLAGS_threads);
    options.idleTimeout = std::chrono::milliseconds(60000);
    options.shutdownOn = {SIGINT, SIGTERM};
    // Nothing here speaks CONNECT; saying we do only stops HTTPServer from
    // prepending RejectConnectFilterFactory to the per-request filter chain.
    options.supportsConnect = true;
    options.enableContentCompression = true;
    // Only `json-comp` asks for a compressed response, and it is the one
    // profile scored on compression ratio rather than raw rps. `static` sends
    // `Accept-Encoding: br;q=1, gzip;q=0.8` too, and proxygen's default
    // compressible set covers text/css, text/html and application/javascript —
    // so every CSS/JS/HTML request was gzipping 8-200 KB on the event base for
    // no scoring benefit (compression is explicitly optional for `static`).
    // Restrict the set to the content type json-comp actually measures.
    options.contentCompressionTypes = {"application/json"};
    options.initialReceiveWindow = 1U << 20;
    options.receiveStreamWindowSize = 1U << 20;
    options.receiveSessionWindowSize = 10U << 20;
    options.maxConcurrentIncomingStreams = 1024;
    options.handlerFactories =
        RequestHandlerChain()
            .addThen<ArenaHandlerFactory>(dataset, assets)
            .build();

    httparena::ArenaHQServer h3Server(
        FLAGS_cert, FLAGS_key, static_cast<size_t>(FLAGS_h3_threads),
        [dataset](HTTPMessage *) -> proxygen::HTTPTransactionHandler * {
          return new proxygen::RequestHandlerAdaptor(
              new ArenaHandler(*dataset, assets));
        });
    HTTPServer server(std::move(options));
    server.bind(listenerConfigs());
    h3Server.start(SocketAddress(FLAGS_ip, FLAGS_h3_port, true));
    server.start();
    h3Server.stop();
  } catch (const std::exception &error) {
    std::cerr << "failed to start Proxygen HttpArena server: " << error.what()
              << '\n';
    return 1;
  }
  return 0;
}
