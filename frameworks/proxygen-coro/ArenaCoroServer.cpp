#include <algorithm>
#include <array>
#include <cctype>
#include <charconv>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <deque>
#include <fstream>
#include <future>
#include <iostream>
#include <iterator>
#include <limits>
#include <list>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <folly/ScopeGuard.h>
#include <folly/base64.h>
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
#include <proxygen/lib/http/coro/filters/CompressionFilterFactory.h>
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
DEFINE_int32(threads, 0, "I/O threads; 0 uses the available CPU count");

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

constexpr size_t kMaxBaselineBody = 1024;
constexpr uint64_t kMaxWebSocketMessage = 16ULL * 1024 * 1024;
constexpr std::string_view kJsonPrefix = "/json/";
constexpr std::string_view kStaticPrefix = "/static/";
constexpr std::string_view kStaticRoot = "/data/static/";

bool parseInteger(std::string_view input, int64_t &value) {
  while (!input.empty() &&
         std::isspace(static_cast<unsigned char>(input.front()))) {
    input.remove_prefix(1);
  }
  while (!input.empty() &&
         std::isspace(static_cast<unsigned char>(input.back()))) {
    input.remove_suffix(1);
  }
  if (input.empty()) {
    return false;
  }
  const auto result =
      std::from_chars(input.data(), input.data() + input.size(), value);
  return result.ec == std::errc() && result.ptr == input.data() + input.size();
}

bool checkedAdd(int64_t lhs, int64_t rhs, int64_t &result) {
#if defined(__GNUC__) || defined(__clang__)
  return !__builtin_add_overflow(lhs, rhs, &result);
#else
  if ((rhs > 0 && lhs > std::numeric_limits<int64_t>::max() - rhs) ||
      (rhs < 0 && lhs < std::numeric_limits<int64_t>::min() - rhs)) {
    return false;
  }
  result = lhs + rhs;
  return true;
#endif
}

bool checkedMultiply(int64_t lhs, int64_t rhs, int64_t &result) {
#if defined(__GNUC__) || defined(__clang__)
  return !__builtin_mul_overflow(lhs, rhs, &result);
#else
  if (lhs > 0) {
    if ((rhs > 0 && lhs > std::numeric_limits<int64_t>::max() / rhs) ||
        (rhs < 0 && rhs < std::numeric_limits<int64_t>::min() / lhs)) {
      return false;
    }
  } else if (lhs < 0) {
    if ((rhs > 0 && lhs < std::numeric_limits<int64_t>::min() / rhs) ||
        (rhs < 0 && rhs < std::numeric_limits<int64_t>::max() / lhs)) {
      return false;
    }
  }
  result = lhs * rhs;
  return true;
#endif
}

std::string contentType(std::string_view name) {
  const auto endsWith = [name](std::string_view suffix) {
    return name.size() >= suffix.size() &&
           name.substr(name.size() - suffix.size()) == suffix;
  };
  if (endsWith(".css")) {
    return "text/css";
  }
  if (endsWith(".js")) {
    return "application/javascript";
  }
  if (endsWith(".html")) {
    return "text/html";
  }
  if (endsWith(".json")) {
    return "application/json";
  }
  if (endsWith(".svg")) {
    return "image/svg+xml";
  }
  if (endsWith(".webp")) {
    return "image/webp";
  }
  if (endsWith(".woff2")) {
    return "font/woff2";
  }
  return "application/octet-stream";
}

std::shared_ptr<const folly::dynamic> loadDataset() {
  std::ifstream input("/data/dataset.json", std::ios::binary);
  if (!input) {
    throw std::runtime_error("cannot open /data/dataset.json");
  }
  std::string contents((std::istreambuf_iterator<char>(input)),
                       std::istreambuf_iterator<char>());
  auto dataset = folly::parseJson(contents);
  if (!dataset.isArray() || dataset.size() < 50) {
    throw std::runtime_error("/data/dataset.json must contain 50 items");
  }
  return std::make_shared<const folly::dynamic>(std::move(dataset));
}

bool validWebSocketKey(std::string_view key) noexcept {
  if (key.size() != 24) {
    return false;
  }
  std::array<char, 18> decoded{};
  const auto result = folly::base64Decode(key, decoded.data());
  return result.is_success && result.o == decoded.data() + 16;
}

bool validUtf8(const uint8_t *data, size_t size) noexcept {
  const auto continuation = [](uint8_t byte) {
    return byte >= 0x80 && byte <= 0xbf;
  };

  size_t index = 0;
  while (index < size) {
    const uint8_t first = data[index];
    if (first <= 0x7f) {
      ++index;
      continue;
    }
    if (first >= 0xc2 && first <= 0xdf) {
      if (index + 1 >= size || !continuation(data[index + 1])) {
        return false;
      }
      index += 2;
      continue;
    }
    if (first == 0xe0) {
      if (index + 2 >= size || data[index + 1] < 0xa0 ||
          data[index + 1] > 0xbf || !continuation(data[index + 2])) {
        return false;
      }
      index += 3;
      continue;
    }
    if ((first >= 0xe1 && first <= 0xec) || (first >= 0xee && first <= 0xef)) {
      if (index + 2 >= size || !continuation(data[index + 1]) ||
          !continuation(data[index + 2])) {
        return false;
      }
      index += 3;
      continue;
    }
    if (first == 0xed) {
      if (index + 2 >= size || data[index + 1] < 0x80 ||
          data[index + 1] > 0x9f || !continuation(data[index + 2])) {
        return false;
      }
      index += 3;
      continue;
    }
    if (first == 0xf0) {
      if (index + 3 >= size || data[index + 1] < 0x90 ||
          data[index + 1] > 0xbf || !continuation(data[index + 2]) ||
          !continuation(data[index + 3])) {
        return false;
      }
      index += 4;
      continue;
    }
    if (first >= 0xf1 && first <= 0xf3) {
      if (index + 3 >= size || !continuation(data[index + 1]) ||
          !continuation(data[index + 2]) || !continuation(data[index + 3])) {
        return false;
      }
      index += 4;
      continue;
    }
    if (first == 0xf4) {
      if (index + 3 >= size || data[index + 1] < 0x80 ||
          data[index + 1] > 0x8f || !continuation(data[index + 2]) ||
          !continuation(data[index + 3])) {
        return false;
      }
      index += 4;
      continue;
    }
    return false;
  }
  return true;
}

bool validUtf8(const std::vector<uint8_t> &data) noexcept {
  return validUtf8(data.data(), data.size());
}

bool validWebSocketCloseCode(uint16_t code) noexcept {
  const bool definedProtocolCode = code >= 1000 && code <= 1014 &&
                                   code != 1004 && code != 1005 && code != 1006;
  const bool applicationCode = code >= 3000 && code <= 4999;
  return definedProtocolCode || applicationCode;
}

HTTPFixedSource *makeResponse(uint16_t status,
                              std::string_view contentTypeValue,
                              std::string body) {
  auto *response = HTTPFixedSource::makeFixedResponse(status, std::move(body));
  response->msg_->getHeaders().set(proxygen::HTTP_HEADER_CONTENT_TYPE,
                                   contentTypeValue);
  return response;
}

HTTPFixedSource *makeTextResponse(uint16_t status, std::string body) {
  return makeResponse(status, "text/plain", std::move(body));
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
    while (pending_.empty()) {
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
        auto body = input.event.body.move();
        if (body) {
          const auto range = body->coalesce();
          input_.insert(input_.end(), range.begin(), range.end());
          processFrames();
        }
      }
      if (input.eom && !finished_) {
        finished_ = true;
        if (pending_.empty()) {
          pending_.push_back(PendingOutput{{}, 0, true});
        } else {
          pending_.back().eom = true;
        }
      }
    }

    auto &front = pending_.front();
    const size_t remaining = front.bytes.size() - front.offset;
    const size_t limit = std::max<size_t>(1, max);
    const size_t amount = std::min(remaining, limit);
    std::unique_ptr<folly::IOBuf> body;
    if (amount > 0) {
      body =
          folly::IOBuf::copyBuffer(front.bytes.data() + front.offset, amount);
      front.offset += amount;
    }
    const bool outputEom = front.eom && front.offset == front.bytes.size();
    if (front.offset == front.bytes.size()) {
      pending_.pop_front();
    }
    HTTPBodyEvent event(std::move(body), outputEom);
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
  struct PendingOutput {
    std::vector<uint8_t> bytes;
    size_t offset{0};
    bool eom{false};
  };

  void queueEom() {
    if (!finished_) {
      finished_ = true;
      pending_.push_back(PendingOutput{{}, 0, true});
    }
  }

  void queueFrame(uint8_t opcode, const uint8_t *payload, size_t payloadLength,
                  bool eom = false) {
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
    pending_.push_back(PendingOutput{std::move(frame), 0, eom});
  }

  void queueFrame(uint8_t opcode, const std::vector<uint8_t> &payload,
                  bool eom = false) {
    queueFrame(opcode, payload.data(), payload.size(), eom);
  }

  void closeWith(uint16_t status) {
    if (closeSent_ || finished_) {
      return;
    }
    const std::array<uint8_t, 2> payload = {
        static_cast<uint8_t>((status >> 8) & 0xff),
        static_cast<uint8_t>(status & 0xff)};
    queueFrame(0x08, payload.data(), payload.size());
    closeSent_ = true;
  }

  void protocolError() { closeWith(1002); }

  void invalidPayload() { closeWith(1007); }

  void handleFrame(bool fin, uint8_t opcode, std::vector<uint8_t> payload) {
    if (closeSent_ && opcode != 0x08) {
      return;
    }

    if ((opcode & 0x08U) != 0) {
      if (!fin || payload.size() > 125) {
        protocolError();
        return;
      }
      if (opcode == 0x08) {
        if (payload.size() == 1) {
          protocolError();
          return;
        }
        if (payload.size() >= 2) {
          const uint16_t status =
              (static_cast<uint16_t>(payload[0]) << 8) | payload[1];
          if (!validWebSocketCloseCode(status)) {
            protocolError();
            return;
          }
          if (!validUtf8(payload.data() + 2, payload.size() - 2)) {
            invalidPayload();
            return;
          }
        }
        if (closeSent_) {
          queueEom();
          return;
        }
        finished_ = true;
        queueFrame(0x08, payload, true);
      } else if (opcode == 0x09) {
        queueFrame(0x0a, payload);
      } else if (opcode != 0x0a) {
        protocolError();
      }
      return;
    }

    if (opcode == 0x00) {
      if (fragmentOpcode_ == 0 ||
          payload.size() > kMaxWebSocketMessage - fragmentPayload_.size()) {
        protocolError();
        return;
      }
      fragmentPayload_.insert(fragmentPayload_.end(), payload.begin(),
                              payload.end());
      if (fin) {
        if (fragmentOpcode_ == 0x01 && !validUtf8(fragmentPayload_)) {
          invalidPayload();
          return;
        }
        queueFrame(fragmentOpcode_, fragmentPayload_);
        fragmentOpcode_ = 0;
        fragmentPayload_.clear();
      }
      return;
    }

    if ((opcode != 0x01 && opcode != 0x02) || fragmentOpcode_ != 0) {
      protocolError();
      return;
    }
    if (fin) {
      if (opcode == 0x01 && !validUtf8(payload)) {
        invalidPayload();
        return;
      }
      queueFrame(opcode, payload);
      return;
    }
    fragmentOpcode_ = opcode;
    fragmentPayload_ = std::move(payload);
  }

  void processFrames() {
    size_t cursor = 0;
    while (!finished_) {
      if (input_.size() - cursor < 2) {
        break;
      }
      const uint8_t first = input_[cursor];
      const uint8_t second = input_[cursor + 1];
      const bool fin = (first & 0x80U) != 0;
      const uint8_t opcode = first & 0x0fU;
      const uint8_t encodedLength = second & 0x7fU;
      if ((first & 0x70U) != 0 || (second & 0x80U) == 0 ||
          ((opcode & 0x08U) != 0 && encodedLength > 125)) {
        protocolError();
        cursor = input_.size();
        break;
      }

      uint64_t payloadLength = encodedLength;
      size_t headerLength = 2;
      if (payloadLength == 126) {
        if (input_.size() - cursor < 4) {
          break;
        }
        payloadLength = (static_cast<uint64_t>(input_[cursor + 2]) << 8) |
                        input_[cursor + 3];
        if (payloadLength < 126) {
          protocolError();
          cursor = input_.size();
          break;
        }
        headerLength = 4;
      } else if (payloadLength == 127) {
        if (input_.size() - cursor < 10) {
          break;
        }
        if ((input_[cursor + 2] & 0x80U) != 0) {
          protocolError();
          cursor = input_.size();
          break;
        }
        payloadLength = 0;
        for (size_t index = 0; index < 8; ++index) {
          payloadLength = (payloadLength << 8) | input_[cursor + 2 + index];
        }
        if (payloadLength <= std::numeric_limits<uint16_t>::max()) {
          protocolError();
          cursor = input_.size();
          break;
        }
        headerLength = 10;
      }
      if (payloadLength > kMaxWebSocketMessage ||
          payloadLength >
              std::numeric_limits<size_t>::max() - headerLength - 4) {
        protocolError();
        cursor = input_.size();
        break;
      }

      const size_t frameLength =
          headerLength + 4 + static_cast<size_t>(payloadLength);
      if (input_.size() - cursor < frameLength) {
        break;
      }
      const size_t maskOffset = cursor + headerLength;
      const size_t payloadOffset = maskOffset + 4;
      std::vector<uint8_t> payload(static_cast<size_t>(payloadLength));
      for (size_t index = 0; index < payload.size(); ++index) {
        payload[index] =
            input_[payloadOffset + index] ^ input_[maskOffset + (index % 4)];
      }
      cursor += frameLength;
      handleFrame(fin, opcode, std::move(payload));
      if (closeSent_ || finished_) {
        break;
      }
    }

    if (cursor > 0) {
      input_.erase(input_.begin(), input_.begin() + cursor);
    }
    if (closeSent_ || finished_) {
      input_.clear();
    }
  }

  HTTPSourceHolder request_;
  std::deque<PendingOutput> pending_;
  std::vector<uint8_t> input_;
  std::vector<uint8_t> fragmentPayload_;
  uint8_t fragmentOpcode_{0};
  bool closeSent_{false};
  bool finished_{false};
};

class ArenaCoroHandler final : public HTTPHandler {
public:
  explicit ArenaCoroHandler(std::shared_ptr<const folly::dynamic> dataset)
      : dataset_(std::move(dataset)) {}

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
    const std::string path = request->getPath();

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
      if (!parseInteger(request->getQueryParam("a"), a) ||
          !parseInteger(request->getQueryParam("b"), b)) {
        co_return makeTextResponse(400, "invalid integer");
      }
      int64_t sum = 0;
      if (!checkedAdd(a, b, sum)) {
        co_return makeTextResponse(400, "integer overflow");
      }
      if (method == HTTPMethod::POST) {
        auto body = co_await readRequestBody(requestSource, requestEom,
                                             kMaxBaselineBody);
        int64_t bodyValue = 0;
        if (!body.readOk || !body.captureOk ||
            !parseInteger(body.captured, bodyValue) ||
            !checkedAdd(sum, bodyValue, sum)) {
          co_return makeTextResponse(400, "invalid integer");
        }
      }
      co_return makeTextResponse(200, std::to_string(sum));
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
      const auto multiplierText = request->getQueryParam("m");
      if (!parseInteger(countText, count) || count < 1 || count > 50 ||
          (!multiplierText.empty() &&
           !parseInteger(multiplierText, multiplier))) {
        co_return makeTextResponse(400, "invalid JSON parameters");
      }

      try {
        folly::dynamic items = folly::dynamic::array;
        for (int64_t index = 0; index < count; ++index) {
          folly::dynamic item = (*dataset_)[static_cast<size_t>(index)];
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
        co_return makeResponse(200, "application/json",
                               folly::toJson(response));
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
      co_return makeTextResponse(200, std::to_string(body.size));
    }

    if (path.starts_with(kStaticPrefix)) {
      if (method != HTTPMethod::GET) {
        co_return makeTextResponse(405, "method not allowed");
      }
      const std::string name(path.data() + kStaticPrefix.size(),
                             path.size() - kStaticPrefix.size());
      if (name.empty() || name.find('/') != std::string::npos ||
          name.find('\\') != std::string::npos ||
          name.find("..") != std::string::npos) {
        co_return makeTextResponse(404, "not found");
      }
      std::ifstream input(std::string(kStaticRoot) + name, std::ios::binary);
      if (!input) {
        co_return makeTextResponse(404, "not found");
      }
      std::string body((std::istreambuf_iterator<char>(input)),
                       std::istreambuf_iterator<char>());
      if (!input.good() && !input.eof()) {
        co_return makeTextResponse(500, "read error");
      }
      co_return makeResponse(200, contentType(name), std::move(body));
    }

    co_return makeTextResponse(404, "not found");
  }

private:
  std::shared_ptr<const folly::dynamic> dataset_;
};

std::shared_ptr<const std::set<std::string>> compressibleTypes() {
  return std::make_shared<const std::set<std::string>>(std::set<std::string>{
      "application/javascript", "application/json", "image/svg+xml", "text/css",
      "text/html", "text/plain"});
}

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

void addCompressionFilter(HTTPServer::Config &config) {
  proxygen::CompressionFilterUtils::FactoryOptions options;
  options.compressibleContentTypes = compressibleTypes();
  config.filterFactories.push_back(
      std::make_shared<proxygen::coro::ServerCompressionFilterFactory>(
          std::move(options)));
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
  addCompressionFilter(config);
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
  addCompressionFilter(config);
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
    auto handler = std::make_shared<ArenaCoroHandler>(std::move(dataset));

    HTTPServer tcpServer(tcpConfig(threads), handler, tcpSocketFactory());
    HTTPServer h3Server(quicConfig(threads), std::move(handler));

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
