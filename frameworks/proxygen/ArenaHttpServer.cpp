#include "ArenaCommon.h"
#include "ArenaHQServer.h"

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <exception>
#include <fstream>
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
DEFINE_int32(threads, 0, "I/O threads; 0 uses the available CPU count");

namespace {

constexpr size_t kMaxRequestBody = 1024;
using httparena::checkedAdd;
using httparena::checkedMultiply;
using httparena::contentType;
using httparena::kJsonPrefix;
using httparena::kMaxWebSocketMessage;
using httparena::kStaticPrefix;
using httparena::kStaticRoot;
using httparena::loadDataset;
using httparena::parseInteger;
using httparena::validUtf8;
using httparena::validWebSocketCloseCode;
using httparena::validWebSocketKey;

class ArenaHandler final : public RequestHandler {
public:
  explicit ArenaHandler(std::shared_ptr<const folly::dynamic> dataset)
      : dataset_(std::move(dataset)) {}

  void onRequest(std::unique_ptr<HTTPMessage> request) noexcept override {
    const auto path = request->getPath();
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
    if (path == "/baseline11") {
      route_ = Route::Baseline;
      queryValid_ = parseInteger(request->getQueryParam("a"), a_) &&
                    parseInteger(request->getQueryParam("b"), b_);
      return;
    }
    if (path == "/baseline2") {
      route_ = Route::BaselineH2;
      queryValid_ = parseInteger(request->getQueryParam("a"), a_) &&
                    parseInteger(request->getQueryParam("b"), b_);
      return;
    }
    if (path.starts_with(kJsonPrefix)) {
      route_ = Route::Json;
      const std::string_view countText(path.data() + kJsonPrefix.size(),
                                       path.size() - kJsonPrefix.size());
      int64_t count = 0;
      const auto multiplierText = request->getQueryParam("m");
      const bool multiplierValid =
          multiplierText.empty() ? (multiplier_ = 1, true)
                                 : parseInteger(multiplierText, multiplier_);
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
    if (path.starts_with(kStaticPrefix)) {
      route_ = Route::Static;
      staticName_.assign(path.data() + kStaticPrefix.size(),
                         path.size() - kStaticPrefix.size());
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
      auto bytes = body->coalesce();
      websocketBytes_.insert(websocketBytes_.end(), bytes.begin(), bytes.end());
      processWebSocketFrames();
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
        sendText(200, "OK", std::to_string(uploadBytes_));
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
    sendText(200, "OK", std::to_string(sum));
  }

  void handleJson() {
    if (method_ != HTTPMethod::GET) {
      sendText(405, "Method Not Allowed", "method not allowed");
      return;
    }
    if (!jsonValid_ || jsonCount_ > dataset_->size()) {
      sendText(400, "Bad Request", "invalid JSON parameters");
      return;
    }

    try {
      folly::dynamic items = folly::dynamic::array;
      for (size_t index = 0; index < jsonCount_; ++index) {
        folly::dynamic item = (*dataset_)[index];
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
      sendResponse(200, "OK", "application/json", folly::toJson(response));
    } catch (const std::exception &) {
      sendText(500, "Internal Server Error", "JSON serialization failed");
    }
  }

  void handleStatic() {
    if (method_ != HTTPMethod::GET) {
      sendText(405, "Method Not Allowed", "method not allowed");
      return;
    }
    if (staticName_.empty() || staticName_.find('/') != std::string::npos ||
        staticName_.find('\\') != std::string::npos ||
        staticName_.find("..") != std::string::npos) {
      sendText(404, "Not Found", "not found");
      return;
    }

    std::ifstream input(std::string(kStaticRoot) + staticName_,
                        std::ios::binary);
    if (!input) {
      sendText(404, "Not Found", "not found");
      return;
    }
    std::string body((std::istreambuf_iterator<char>(input)),
                     std::istreambuf_iterator<char>());
    if (!input.good() && !input.eof()) {
      sendText(500, "Internal Server Error", "read error");
      return;
    }
    sendResponse(200, "OK", contentType(staticName_), std::move(body));
  }

  void sendResponse(uint16_t status, const std::string &reason,
                    const std::string &type, std::string body) {
    responseFinished_ = true;
    ResponseBuilder(downstream_)
        .status(status, reason)
        .header("Content-Type", type)
        .body(std::move(body))
        .sendWithEOM();
  }

  void sendText(uint16_t status, const std::string &reason,
                const std::string &body) {
    sendResponse(status, reason, "text/plain", body);
  }

  void sendWebSocketFrame(uint8_t opcode, const uint8_t *payload,
                          size_t payloadLength) {
    std::vector<uint8_t> frame;
    frame.reserve(payloadLength + 10);
    frame.push_back(static_cast<uint8_t>(0x80U | opcode));
    if (payloadLength <= 125) {
      frame.push_back(static_cast<uint8_t>(payloadLength));
    } else if (payloadLength <= std::numeric_limits<uint16_t>::max()) {
      frame.push_back(126);
      frame.push_back(static_cast<uint8_t>((payloadLength >> 8) & 0xff));
      frame.push_back(static_cast<uint8_t>(payloadLength & 0xff));
    } else {
      frame.push_back(127);
      const auto length = static_cast<uint64_t>(payloadLength);
      for (int shift = 56; shift >= 0; shift -= 8) {
        frame.push_back(static_cast<uint8_t>((length >> shift) & 0xff));
      }
    }
    if (payloadLength > 0) {
      frame.insert(frame.end(), payload, payload + payloadLength);
    }
    downstream_->sendBody(folly::IOBuf::copyBuffer(frame.data(), frame.size()));
  }

  void sendWebSocketFrame(uint8_t opcode, const std::vector<uint8_t> &payload) {
    sendWebSocketFrame(opcode, payload.data(), payload.size());
  }

  void closeWebSocket(uint16_t status) {
    if (responseFinished_ || closeSent_) {
      return;
    }
    const std::array<uint8_t, 2> payload = {
        static_cast<uint8_t>((status >> 8) & 0xff),
        static_cast<uint8_t>(status & 0xff)};
    sendWebSocketFrame(0x8, payload.data(), payload.size());
    closeSent_ = true;
  }

  void webSocketProtocolError() { closeWebSocket(1002); }

  void webSocketInvalidPayload() { closeWebSocket(1007); }

  void handleWebSocketFrame(bool fin, uint8_t opcode,
                            std::vector<uint8_t> payload) {
    if (closeSent_ && opcode != 0x08) {
      return;
    }
    if ((opcode & 0x08U) != 0) {
      if (!fin || payload.size() > 125) {
        webSocketProtocolError();
        return;
      }
      if (opcode == 0x08) {
        if (payload.size() == 1) {
          webSocketProtocolError();
          return;
        }
        if (payload.size() >= 2) {
          const uint16_t status =
              (static_cast<uint16_t>(payload[0]) << 8) | payload[1];
          if (!validWebSocketCloseCode(status)) {
            webSocketProtocolError();
            return;
          }
          if (!validUtf8(payload.data() + 2, payload.size() - 2)) {
            webSocketInvalidPayload();
            return;
          }
        }
        if (closeSent_) {
          responseFinished_ = true;
          downstream_->sendEOM();
          return;
        }
        sendWebSocketFrame(0x08, payload);
        responseFinished_ = true;
        downstream_->sendEOM();
      } else if (opcode == 0x09) {
        sendWebSocketFrame(0x0a, payload);
      } else if (opcode != 0x0a) {
        webSocketProtocolError();
      }
      return;
    }

    if (opcode == 0x00) {
      if (fragmentOpcode_ == 0) {
        webSocketProtocolError();
        return;
      }
      if (fragmentPayload_.size() + payload.size() > kMaxWebSocketMessage) {
        webSocketProtocolError();
        return;
      }
      fragmentPayload_.insert(fragmentPayload_.end(), payload.begin(),
                              payload.end());
      if (fin) {
        if (fragmentOpcode_ == 0x01 && !validUtf8(fragmentPayload_)) {
          webSocketInvalidPayload();
          return;
        }
        sendWebSocketFrame(fragmentOpcode_, fragmentPayload_);
        fragmentOpcode_ = 0;
        fragmentPayload_.clear();
      }
      return;
    }

    if (opcode != 0x01 && opcode != 0x02) {
      webSocketProtocolError();
      return;
    }
    if (fragmentOpcode_ != 0) {
      webSocketProtocolError();
      return;
    }
    if (fin) {
      if (opcode == 0x01 && !validUtf8(payload)) {
        webSocketInvalidPayload();
        return;
      }
      sendWebSocketFrame(opcode, payload);
      return;
    }
    fragmentOpcode_ = opcode;
    fragmentPayload_ = std::move(payload);
  }

  void processWebSocketFrames() {
    size_t cursor = 0;
    while (!responseFinished_) {
      if (websocketBytes_.size() - cursor < 2) {
        break;
      }
      const uint8_t first = websocketBytes_[cursor];
      const uint8_t second = websocketBytes_[cursor + 1];
      const bool fin = (first & 0x80U) != 0;
      const uint8_t opcode = first & 0x0fU;
      const uint8_t encodedPayloadLength = second & 0x7fU;
      if ((first & 0x70U) != 0 || (second & 0x80U) == 0) {
        webSocketProtocolError();
        break;
      }
      // RFC 6455 control frames cannot use either extended-length encoding,
      // even when that encoding ultimately describes 125 bytes or fewer.
      if ((opcode & 0x08U) != 0 && encodedPayloadLength > 125) {
        webSocketProtocolError();
        break;
      }

      uint64_t payloadLength = encodedPayloadLength;
      size_t headerLength = 2;
      if (payloadLength == 126) {
        if (websocketBytes_.size() - cursor < 4) {
          break;
        }
        payloadLength =
            (static_cast<uint64_t>(websocketBytes_[cursor + 2]) << 8) |
            websocketBytes_[cursor + 3];
        if (payloadLength < 126) {
          webSocketProtocolError();
          break;
        }
        headerLength = 4;
      } else if (payloadLength == 127) {
        if (websocketBytes_.size() - cursor < 10) {
          break;
        }
        if ((websocketBytes_[cursor + 2] & 0x80U) != 0) {
          webSocketProtocolError();
          break;
        }
        payloadLength = 0;
        for (size_t index = 0; index < 8; ++index) {
          payloadLength =
              (payloadLength << 8) | websocketBytes_[cursor + 2 + index];
        }
        if (payloadLength <= std::numeric_limits<uint16_t>::max()) {
          webSocketProtocolError();
          break;
        }
        headerLength = 10;
      }
      if (payloadLength > kMaxWebSocketMessage) {
        webSocketProtocolError();
        break;
      }

      constexpr size_t kMaskLength = 4;
      if (payloadLength >
          std::numeric_limits<size_t>::max() - headerLength - kMaskLength) {
        webSocketProtocolError();
        break;
      }
      const size_t frameLength =
          headerLength + kMaskLength + static_cast<size_t>(payloadLength);
      if (websocketBytes_.size() - cursor < frameLength) {
        break;
      }

      const size_t maskOffset = cursor + headerLength;
      const size_t payloadOffset = maskOffset + kMaskLength;
      std::vector<uint8_t> payload(static_cast<size_t>(payloadLength));
      for (size_t index = 0; index < payload.size(); ++index) {
        payload[index] = websocketBytes_[payloadOffset + index] ^
                         websocketBytes_[maskOffset + (index % kMaskLength)];
      }
      cursor += frameLength;
      handleWebSocketFrame(fin, opcode, std::move(payload));
    }

    if (cursor > 0) {
      websocketBytes_.erase(websocketBytes_.begin(),
                            websocketBytes_.begin() + cursor);
    }
    if (responseFinished_) {
      websocketBytes_.clear();
    }
  }

  Route route_{Route::NotFound};
  std::shared_ptr<const folly::dynamic> dataset_;
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
  bool closeSent_{false};
  bool responseFinished_{false};
  uint8_t fragmentOpcode_{0};
  std::string requestBody_;
  std::string staticName_;
  std::vector<uint8_t> websocketBytes_;
  std::vector<uint8_t> fragmentPayload_;
};

class ArenaHandlerFactory final : public RequestHandlerFactory {
public:
  explicit ArenaHandlerFactory(std::shared_ptr<const folly::dynamic> dataset)
      : dataset_(std::move(dataset)) {}

  void onServerStart(folly::EventBase * /*eventBase*/) noexcept override {}

  void onServerStop() noexcept override {}

  RequestHandler *onRequest(RequestHandler *, HTTPMessage *) noexcept override {
    return new ArenaHandler(dataset_);
  }

private:
  std::shared_ptr<const folly::dynamic> dataset_;
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
  CHECK_GT(FLAGS_threads, 0);

  try {
    auto dataset = loadDataset();

    proxygen::HTTPServerOptions options;
    options.threads = static_cast<size_t>(FLAGS_threads);
    options.idleTimeout = std::chrono::milliseconds(60000);
    options.shutdownOn = {SIGINT, SIGTERM};
    options.supportsConnect = true;
    options.enableContentCompression = true;
    options.initialReceiveWindow = 1U << 20;
    options.receiveStreamWindowSize = 1U << 20;
    options.receiveSessionWindowSize = 10U << 20;
    options.maxConcurrentIncomingStreams = 1024;
    options.handlerFactories =
        RequestHandlerChain().addThen<ArenaHandlerFactory>(dataset).build();

    httparena::ArenaHQServer h3Server(
        FLAGS_cert, FLAGS_key, static_cast<size_t>(FLAGS_threads),
        [dataset](HTTPMessage *) -> proxygen::HTTPTransactionHandler * {
          return new proxygen::RequestHandlerAdaptor(new ArenaHandler(dataset));
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
