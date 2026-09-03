#pragma once

#include <array>
#include <cctype>
#include <charconv>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>

#include <folly/File.h>
#include <folly/FileUtil.h>
#include <folly/base64.h>
#include <folly/dynamic.h>
#include <folly/io/IOBuf.h>
#include <folly/json.h>

namespace httparena {

inline constexpr uint64_t kMaxWebSocketMessage = 16ULL * 1024 * 1024;
inline constexpr size_t kMaxRequestBody = 1024;
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

// Returns the value for `name` in a raw `a=1&b=2` query string, or nullopt if
// it is absent. Scanning beats HTTPMessage::getQueryParam() on the hot path:
// that accessor materialises a std::map<std::string, std::string> of every
// parameter on first use, i.e. two string allocations per parameter per
// request, and `baseline` is the most-requested endpoint in the suite.
inline std::optional<std::string_view> queryValue(std::string_view query,
                                                  std::string_view name) {
  while (!query.empty()) {
    const auto amp = query.find('&');
    const std::string_view field = query.substr(0, amp);
    const auto eq = field.find('=');
    if (eq != std::string_view::npos && field.substr(0, eq) == name) {
      return field.substr(eq + 1);
    }
    if (amp == std::string_view::npos) {
      break;
    }
    query.remove_prefix(amp + 1);
  }
  return std::nullopt;
}

inline std::string_view contentType(std::string_view name) {
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

// ── Static assets ───────────────────────────────────────────────────────────
//
// Read from the mounted directory on every request. The arena's static rules
// require the served bytes to follow the disk — replace a file and the next
// response must carry the new bytes — and explicitly exclude a cache assembled
// in the entry ("no reading the directory into a map at startup"). validate.sh
// enforces this with a staleness probe that swaps the file underneath a running
// server, so a preloaded table fails outright.
//
// Serving the precompressed .br/.gz siblings IS allowed, "by selecting the
// variant in the entry off Accept-Encoding" — those bytes already exist on
// disk, so choosing one is a file read rather than compression. That is where
// the remaining win lives: no gzip on the event-base thread per request.

enum class ContentEncoding : uint8_t { Identity, Gzip, Brotli };

inline std::string_view encodingToken(ContentEncoding encoding) {
  switch (encoding) {
  case ContentEncoding::Brotli:
    return "br";
  case ContentEncoding::Gzip:
    return "gzip";
  case ContentEncoding::Identity:
    break;
  }
  return {};
}

// Token search rather than a full RFC 7231 qvalue parse: the token must be
// delimited so "br" does not match inside another coding, and an explicit
// `q=0` disqualifies it.
inline bool acceptsToken(std::string_view header, std::string_view token) {
  size_t pos = 0;
  while ((pos = header.find(token, pos)) != std::string_view::npos) {
    const bool leftOk =
        pos == 0 || header[pos - 1] == ' ' || header[pos - 1] == ',';
    const size_t after = pos + token.size();
    const bool rightOk = after == header.size() || header[after] == ',' ||
                         header[after] == ';' || header[after] == ' ';
    if (leftOk && rightOk) {
      const auto end = header.find(',', after);
      const auto params =
          header.substr(after, end == std::string_view::npos ? end : end - after);
      const auto q = params.find("q=");
      if (q == std::string_view::npos) {
        return true;
      }
      const auto qv = params.substr(q);
      return !(qv == "q=0" || qv == "q=0.0" || qv.rfind("q=0,", 0) == 0);
    }
    pos = after;
  }
  return false;
}

// Reads `root/name` into a fresh IOBuf: one open, one fstat, one readFull, no
// intermediate std::string. Returns nullptr when the file is absent.
inline std::unique_ptr<folly::IOBuf> readFileToIOBuf(const std::string &path) {
  int fd = folly::openNoInt(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return nullptr;
  }
  folly::File file(fd, /*ownsFd=*/true);
  struct stat info {};
  if (::fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
    return nullptr;
  }
  const auto size = static_cast<size_t>(info.st_size);
  auto buffer = folly::IOBuf::create(size);
  if (size > 0) {
    const ssize_t got = folly::readFull(fd, buffer->writableTail(), size);
    if (got < 0 || static_cast<size_t>(got) != size) {
      return nullptr;
    }
  }
  buffer->append(size);
  return buffer;
}

struct StaticResponse {
  std::unique_ptr<folly::IOBuf> body;
  std::string_view contentType;
  ContentEncoding encoding{ContentEncoding::Identity};
};

// `name` must already be rejected if it contains a separator or "..".
// Prefers the precompressed sibling this client accepts, falling back to the
// original — which is what a client sending no Accept-Encoding always gets.
inline StaticResponse serveStatic(std::string_view name,
                                  std::string_view acceptEncoding) {
  StaticResponse out;
  std::string path;
  path.reserve(kStaticRoot.size() + name.size() + 3);
  path.append(kStaticRoot).append(name);
  const size_t baseLen = path.size();

  if (acceptsToken(acceptEncoding, "br")) {
    path.append(".br");
    out.body = readFileToIOBuf(path);
    if (out.body) {
      out.encoding = ContentEncoding::Brotli;
    }
    path.resize(baseLen);
  }
  if (!out.body && acceptsToken(acceptEncoding, "gzip")) {
    path.append(".gz");
    out.body = readFileToIOBuf(path);
    if (out.body) {
      out.encoding = ContentEncoding::Gzip;
    }
    path.resize(baseLen);
  }
  if (!out.body) {
    out.body = readFileToIOBuf(path);
    out.encoding = ContentEncoding::Identity;
  }
  if (out.body) {
    out.contentType = contentType(name);
  }
  return out;
}

inline std::shared_ptr<const folly::dynamic> loadDataset() {
  std::string contents;
  if (!folly::readFile("/data/dataset.json", contents)) {
    throw std::runtime_error("cannot open /data/dataset.json");
  }
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
