#pragma once

#include <array>
#include <cctype>
#include <charconv>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <folly/base64.h>
#include <folly/dynamic.h>
#include <folly/json.h>

namespace httparena {

inline constexpr uint64_t kMaxWebSocketMessage = 16ULL * 1024 * 1024;
inline constexpr std::string_view kJsonPrefix = "/json/";
inline constexpr std::string_view kStaticPrefix = "/static/";
inline constexpr std::string_view kStaticRoot = "/data/static/";

inline bool parseInteger(std::string_view input, int64_t &value) {
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

inline bool checkedAdd(int64_t lhs, int64_t rhs, int64_t &result) {
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

inline bool checkedMultiply(int64_t lhs, int64_t rhs, int64_t &result) {
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

inline std::string contentType(std::string_view name) {
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

inline std::shared_ptr<const folly::dynamic> loadDataset() {
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

inline bool validWebSocketKey(std::string_view key) noexcept {
  if (key.size() != 24) {
    return false;
  }
  std::array<char, 18> decoded{};
  const auto result = folly::base64Decode(key, decoded.data());
  return result.is_success && result.o == decoded.data() + 16;
}

inline bool validUtf8(const uint8_t *data, size_t size) noexcept {
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

inline bool validUtf8(const std::vector<uint8_t> &data) noexcept {
  return validUtf8(data.data(), data.size());
}

inline bool validWebSocketCloseCode(uint16_t code) noexcept {
  const bool definedProtocolCode = code >= 1000 && code <= 1014 &&
                                   code != 1004 && code != 1005 && code != 1006;
  const bool applicationCode = code >= 3000 && code <= 4999;
  return definedProtocolCode || applicationCode;
}

} // namespace httparena
