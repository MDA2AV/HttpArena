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
// `/data/static` is mounted read-only and never changes during a run, so every
// file and its precompressed `.br` / `.gz` siblings are read once at startup
// and served straight out of memory. Both are explicitly allowed for `engine`
// entries ("No specific rules"), and the alternative — re-reading and, worse,
// re-gzipping 8-200 KB per request on the event base — was costing better than
// an order of magnitude.
//
// Bodies are handed out as non-owning IOBufs over this table, which lives for
// the life of the process: no copy, no allocation for the payload, and no
// atomic refcount on the shared buffer.

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

struct StaticAsset {
  std::string identity;
  std::string brotli; // empty when there is no .br sibling
  std::string gzip;   // empty when there is no .gz sibling
  std::string_view contentType;

  // Picks the best variant this client accepts. Falls back to identity, which
  // is always present, so an absent or unrecognised Accept-Encoding still
  // yields the byte-exact original.
  std::pair<const std::string *, ContentEncoding>
  select(std::string_view acceptEncoding) const {
    if (!brotli.empty() && acceptsToken(acceptEncoding, "br")) {
      return {&brotli, ContentEncoding::Brotli};
    }
    if (!gzip.empty() && acceptsToken(acceptEncoding, "gzip")) {
      return {&gzip, ContentEncoding::Gzip};
    }
    return {&identity, ContentEncoding::Identity};
  }

  // Token search rather than a full RFC 7231 qvalue parse: the token must be
  // delimited so "br" does not match inside another coding, and an explicit
  // `q=0` disqualifies it.
  static bool acceptsToken(std::string_view header, std::string_view token) {
    size_t pos = 0;
    while ((pos = header.find(token, pos)) != std::string_view::npos) {
      const bool leftOk =
          pos == 0 || header[pos - 1] == ' ' || header[pos - 1] == ',';
      const size_t after = pos + token.size();
      const bool rightOk = after == header.size() || header[after] == ',' ||
                           header[after] == ';' || header[after] == ' ';
      if (leftOk && rightOk) {
        // Reject `;q=0` (but not `;q=0.8`).
        const auto end = header.find(',', after);
        const auto params = header.substr(
            after, end == std::string_view::npos ? end : end - after);
        const auto q = params.find("q=");
        if (q == std::string_view::npos ||
            params.compare(q, 4, "q=0,") == 0 || params.substr(q) == "q=0" ||
            params.substr(q) == "q=0.0") {
          return q == std::string_view::npos;
        }
        return true;
      }
      pos = after;
    }
    return false;
  }
};

class StaticAssets {
public:
  // Throws if the mount is missing; the arena always provides it.
  void load() {
    namespace fs = std::filesystem;
    std::error_code ec;
    fs::directory_iterator it(kStaticRoot, ec);
    if (ec) {
      throw std::runtime_error(std::string("cannot scan ") +
                               std::string(kStaticRoot) + ": " + ec.message());
    }
    // Pass 1: the originals. Pass 2 attaches variants, so ordering within the
    // directory listing does not matter.
    std::vector<fs::path> variants;
    for (const auto &entry : it) {
      if (!entry.is_regular_file()) {
        continue;
      }
      const auto name = entry.path().filename().string();
      if (name.ends_with(".br") || name.ends_with(".gz")) {
        variants.push_back(entry.path());
        continue;
      }
      StaticAsset asset;
      if (!folly::readFile(entry.path().c_str(), asset.identity)) {
        continue;
      }
      asset.contentType = contentType(name);
      assets_.emplace(name, std::move(asset));
    }
    for (const auto &path : variants) {
      const auto name = path.filename().string();
      const auto base = name.substr(0, name.size() - 3);
      auto found = assets_.find(base);
      if (found == assets_.end()) {
        continue; // orphan variant with no original; ignore it
      }
      std::string &slot =
          name.ends_with(".br") ? found->second.brotli : found->second.gzip;
      if (!folly::readFile(path.c_str(), slot)) {
        slot.clear();
      }
    }
    if (assets_.empty()) {
      throw std::runtime_error("no static assets found under /data/static");
    }
  }

  // A miss is simply a 404; because this is an exact lookup in a fixed table,
  // path traversal is impossible by construction.
  const StaticAsset *find(std::string_view name) const {
    const auto found = assets_.find(name);
    return found == assets_.end() ? nullptr : &found->second;
  }

private:
  // Transparent hashing so lookups take a string_view without allocating.
  struct Hash {
    using is_transparent = void;
    size_t operator()(std::string_view s) const noexcept {
      return std::hash<std::string_view>{}(s);
    }
  };
  struct Equal {
    using is_transparent = void;
    bool operator()(std::string_view a, std::string_view b) const noexcept {
      return a == b;
    }
  };
  std::unordered_map<std::string, StaticAsset, Hash, Equal> assets_;
};

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
