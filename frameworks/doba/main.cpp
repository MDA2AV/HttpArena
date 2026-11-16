//                              _       _
//                           __| | ___ | |__   __ _
//                          / _` |/ _ \| '_ \ / _` |
//                         | (_| | (_) | |_) | (_| |
//                          \__,_|\___/|_.__/ \__,_|
//
//                              Apache License
//                        Version 2.0, January 2004
//                     http://www.apache.org/licenses/LICENSE-2.0
//
// Copyright 2025 martianLabs
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied. See the License for the specific language governing
// permissions and limitations under the License.

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <iterator>
#include <limits>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#if defined(__linux__)
#include <sched.h>
#endif

#ifndef DOBA_HTTPARENA_FULL
#define DOBA_HTTPARENA_FULL 1
#endif

#if DOBA_HTTPARENA_FULL
#include <rapidjson/document.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>
#include <zlib.h>

#include "https_server.h"
#include "protocol/http/v11/static_file_server.h"
#include "transport/tls.h"
#endif

#include "common/reader.h"
#include "common/task.h"
#include "http_server.h"
#include "protocol/http/common/helpers.h"

using martianlabs::doba::http_server;
using namespace martianlabs::doba::protocol::http::v11;

namespace {
namespace common = martianlabs::doba::common;
using martianlabs::doba::protocol::http::helpers;

#if DOBA_HTTPARENA_FULL
// /////////////////////////////////////////////////////////////////////////////
// +---------------------------------------------------------------------------+
// | [>] gzip_context                                               ( struct ) |
// +---------------------------------------------------------------------------+
// | Reuse zlib buffers per worker. Start fresh gzip for each response;        |
// | never cache JSON or compressed output.                                    |
// +---------------------------------------------------------------------------+
// /////////////////////////////////////////////////////////////////////////////
struct gzip_context {
  // +=========================================================================+
  // | [>] ATTRIBUTEs                                               ( public ) |
  // +-------------------------------------------------------------------------+
  z_stream stream{};
  bool initialized{false};

  // +=========================================================================+
  // | [>] CONSTRUCTORs/DESTRUCTORs                                 ( public ) |
  // +-------------------------------------------------------------------------+
  gzip_context() = default;
  gzip_context(const gzip_context&) = delete;
  gzip_context& operator=(const gzip_context&) = delete;
  ~gzip_context() {
    if (initialized) deflateEnd(&stream);
  }

  // +=========================================================================+
  // | [>] reset                                                    ( public ) |
  // +-------------------------------------------------------------------------+
  bool reset() {
    if (initialized) return deflateReset(&stream) == Z_OK;
    initialized =
        deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16,
                     MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY) == Z_OK;
    return initialized;
  }
};

// /////////////////////////////////////////////////////////////////////////////
// +---------------------------------------------------------------------------+
// | [>] encoding_weights                                         ( function ) |
// +---------------------------------------------------------------------------+
// /////////////////////////////////////////////////////////////////////////////
bool encoding_weights(std::string_view value, std::array<int, 4>& quality) {
  constexpr std::array<std::string_view, 4> names = {"br", "gzip", "identity",
                                                     "*"};
  return helpers::for_each_list_element(
      value, [&quality, &names](std::string_view element) {
        helpers::ows_trim(element);
        const auto coding = helpers::consume_token(element);
        if (coding.empty()) return false;
        auto weight = element.substr(coding.size());
        helpers::ows_trim(weight);
        int q = 1000;
        if (!weight.empty()) {
          if (!helpers::consume_weight(weight)) return false;
          const auto number = weight.substr(weight.find('=') + 1);
          q = (number.front() - '0') * 1000;
          int scale = 100;
          for (std::size_t digit = 2; digit < number.size(); ++digit) {
            q += (number[digit] - '0') * scale;
            scale /= 10;
          }
        }
        for (std::size_t j = 0; j < names.size(); ++j) {
          if (helpers::iequals(coding, names[j])) {
            // A duplicate must not undo a q=0 rejection.
            quality[j] = quality[j] < 0 ? q : std::min(quality[j], q);
            break;
          }
        }
        return true;
      });
}

// /////////////////////////////////////////////////////////////////////////////
// +---------------------------------------------------------------------------+
// | [>] parse_integer                                            ( function ) |
// +---------------------------------------------------------------------------+
// /////////////////////////////////////////////////////////////////////////////
#endif
bool parse_integer(std::string_view source, std::int64_t& value) {
  if (source.empty()) return false;
  const char* first = source.data();
  const char* last = first + source.size();
  const auto [end, error] = std::from_chars(first, last, value);
  return error == std::errc() && end == last;
}

// /////////////////////////////////////////////////////////////////////////////
// +---------------------------------------------------------------------------+
// | [>] checked_add                                              ( function ) |
// +---------------------------------------------------------------------------+
// /////////////////////////////////////////////////////////////////////////////
bool checked_add(std::int64_t a, std::int64_t b, std::int64_t& result) {
  if ((b > 0 && a > std::numeric_limits<std::int64_t>::max() - b) ||
      (b < 0 && a < std::numeric_limits<std::int64_t>::min() - b))
    return false;
  result = a + b;
  return true;
}

// /////////////////////////////////////////////////////////////////////////////
// +---------------------------------------------------------------------------+
// | [>] read_query_sum                                           ( function ) |
// +---------------------------------------------------------------------------+
// /////////////////////////////////////////////////////////////////////////////
bool read_query_sum(const request& req, std::int64_t& value) {
  const auto a = req.get_query_parameter("a");
  const auto b = req.get_query_parameter("b");
  std::int64_t a_value = 0;
  std::int64_t b_value = 0;
  if (!a || !b || !parse_integer(a->second, a_value) ||
      !parse_integer(b->second, b_value)) {
    return false;
  }
  return checked_add(a_value, b_value, value);
}

// /////////////////////////////////////////////////////////////////////////////
// +---------------------------------------------------------------------------+
// | [>] read_body_integer                                        ( function ) |
// +---------------------------------------------------------------------------+
// | Use the same reader for Content-Length and chunked bodies.                |
// +---------------------------------------------------------------------------+
// /////////////////////////////////////////////////////////////////////////////
bool read_body_integer(const request& req, std::int64_t& value) {
  if (!req.has_body_reader()) return false;
  std::array<std::byte, 64> buffer{};
  std::size_t used = 0;
  for (;;) {
    const auto state =
        req.get_body_reader()->read(std::span(buffer).subspan(used));
    if (state.has_error) return false;
    used += state.produced;
    if (state.complete) break;
    if (!state.produced || used == buffer.size()) return false;
  }
  return parse_integer(
      std::string_view(reinterpret_cast<const char*>(buffer.data()), used),
      value);
}
}  // namespace

// /////////////////////////////////////////////////////////////////////////////
// +---------------------------------------------------------------------------+
// | [>] main                                                  ( entry-point ) |
// +---------------------------------------------------------------------------+
// | Serve the HttpArena routes over TCP and TLS.                              |
// +---------------------------------------------------------------------------+
// /////////////////////////////////////////////////////////////////////////////
int main() {
  std::size_t workers =
      std::max<std::size_t>(1, std::thread::hardware_concurrency());
#if defined(__linux__)
  cpu_set_t available;
  CPU_ZERO(&available);
  if (::sched_getaffinity(0, sizeof(available), &available) != 0) {
    std::cerr << "unable to read CPU affinity\n";
    return 1;
  }
  workers = std::max<std::size_t>(1, CPU_COUNT(&available));
  // Docker puts this container's cgroup at the controller root.
  constexpr std::array<const char*, 3> quota_paths = {
      "/sys/fs/cgroup/cpu.max", "/sys/fs/cgroup/cpu/cpu.cfs_quota_us",
      "/sys/fs/cgroup/cpu,cpuacct/cpu.cfs_quota_us"};
  for (std::size_t i = 0; i < quota_paths.size(); ++i) {
    std::ifstream quota_file(quota_paths[i]);
    if (!quota_file) continue;
    std::string quota_text;
    quota_file >> quota_text;
    if (quota_text == "max" || quota_text == "-1") break;
    std::uint64_t quota = 0;
    std::uint64_t period = 0;
    const auto [end, error] = std::from_chars(
        quota_text.data(), quota_text.data() + quota_text.size(), quota);
    if (i == 0) {
      quota_file >> period;
    } else {
      std::ifstream period_file(
          std::filesystem::path(quota_paths[i]).parent_path() /
          "cpu.cfs_period_us");
      period_file >> period;
    }
    if (error != std::errc() || end != quota_text.data() + quota_text.size() ||
        !quota || !period) {
      std::cerr << "invalid CPU quota\n";
      return 1;
    }
    // Like Fulmine, use whole CPU cores, with at least one worker.
    const auto quota_workers = std::max<std::uint64_t>(1, quota / period);
    workers = static_cast<std::size_t>(
        std::min<std::uint64_t>(workers, quota_workers));
    break;
  }
#endif
  if (const char* configured = std::getenv("WORKERS")) {
    const std::string_view text(configured);
    std::size_t requested = 0;
    const auto [end, error] =
        std::from_chars(text.data(), text.data() + text.size(), requested);
    if (error != std::errc() || end != text.data() + text.size() ||
        requested == 0) {
      std::cerr << "WORKERS must be a positive integer\n";
      return 1;
    }
    workers = requested;
  }
  std::string port = "8080";
  if (const char* configured = std::getenv("PORT")) {
    std::int64_t requested = 0;
    if (!parse_integer(configured, requested) || requested < 1 ||
        requested > 65535) {
      std::cerr << "PORT must be an integer from 1 to 65535\n";
      return 1;
    }
    port = std::to_string(requested);
  }
#if DOBA_HTTPARENA_FULL
  const char* dataset_path = std::getenv("DATASET_PATH");
  std::ifstream dataset_file(dataset_path ? dataset_path
                                          : "/data/dataset.json");
  if (!dataset_file) {
    std::cerr << "unable to open dataset\n";
    return 1;
  }
  const std::string dataset_text(std::istreambuf_iterator<char>{dataset_file},
                                 std::istreambuf_iterator<char>{});
  rapidjson::Document dataset;
  dataset.Parse(dataset_text.c_str());
  if (dataset.HasParseError() || !dataset.IsArray()) {
    std::cerr << "invalid dataset\n";
    return 1;
  }
#endif
  policies http_configuration;
  http_server<> http_server(
      {.worker_count = workers, .ip = "0.0.0.0", .port = port},
      http_configuration);
  http_server.add_route("GET", "/pipeline", [](const request&, response& res) {
    res.ok_200();
    res.add_header("Content-Type", "text/plain").set_body("ok");
  });
  // Parse every value; HttpArena changes them to catch canned replies.
  http_server.add_route("GET", "/baseline11",
                        [](const request& req, response& res) {
                          res.ok_200();
                          std::int64_t value = 0;
                          if (!read_query_sum(req, value)) {
                            res.bad_request_400();
                            res.set_body("invalid request");
                            return;
                          }
                          res.add_header("Content-Type", "text/plain")
                              .set_body(std::to_string(value));
                        });
  http_server.add_route("POST", "/baseline11",
                        [](const request& req, response& res) {
                          res.ok_200();
                          std::int64_t value = 0;
                          std::int64_t body_value = 0;
                          if (!read_query_sum(req, value) ||
                              !read_body_integer(req, body_value) ||
                              !checked_add(value, body_value, value)) {
                            res.bad_request_400();
                            res.set_body("invalid request");
                            return;
                          }
                          res.add_header("Content-Type", "text/plain")
                              .set_body(std::to_string(value));
                        });
  http_server.add_route(
      "GET", "/delay/:ms",
      [](const request&, response& res,
         std::string_view milliseconds) -> martianlabs::doba::common::task<> {
        std::int64_t delay = 0;
        if (!parse_integer(milliseconds, delay) || delay < 0 || delay > 60000) {
          res.bad_request_400().set_body("invalid delay");
          co_return;
        }
        co_await martianlabs::doba::common::sleep_for(
            std::chrono::milliseconds(delay));
        res.ok_200()
            .add_header("Content-Type", "text/plain")
            .set_body(std::to_string(delay));
      });
#if DOBA_HTTPARENA_FULL
  auto json_handler = [&dataset](const request& req, response& res,
                                 std::uint64_t requested_count) {
    res.ok_200();
    std::int64_t multiplier = 1;
    const auto m = req.get_query_parameter("m");
    if (m && !parse_integer(m->second, multiplier)) {
      res.bad_request_400();
      res.set_body("invalid multiplier");
      return;
    }
    res.add_header("Vary", "Accept-Encoding");
    std::array<int, 4> quality = {-1, -1, -1, -1};
    for (std::size_t i = 0; i < req.get_headers_length(); ++i) {
      const auto header = req.get_header(i);
      if (helpers::iequals(header.first, "Accept-Encoding") &&
          !encoding_weights(header.second, quality)) {
        res.bad_request_400();
        return;
      }
    }
    // RFC 9110 S12.5.3: explicit codings override the wildcard.
    if (quality[1] < 0) quality[1] = std::max(0, quality[3]);
    if (quality[2] < 0) quality[2] = quality[3] == 0 ? 0 : 1;
    if (quality[1] == 0 && quality[2] == 0) {
      res.not_acceptable_406();
      return;
    }
    const bool gzip = quality[1] > 0 && quality[1] >= quality[2];
    const auto count = std::min<std::uint64_t>(requested_count, dataset.Size());
    rapidjson::StringBuffer buffer;
    rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
    writer.StartObject();
    writer.Key("items");
    writer.StartArray();
    for (std::uint64_t i = 0; i < count; ++i) {
      const auto& item = dataset[static_cast<rapidjson::SizeType>(i)];
      writer.StartObject();
      for (auto field = item.MemberBegin(); field != item.MemberEnd();
           ++field) {
        field->name.Accept(writer);
        field->value.Accept(writer);
      }
      writer.Key("total");
      writer.Int64(item["price"].GetInt64() * item["quantity"].GetInt64() *
                   multiplier);
      writer.EndObject();
    }
    writer.EndArray();
    writer.Key("count");
    writer.Uint64(count);
    writer.EndObject();

    std::string_view body(buffer.GetString(), buffer.GetSize());
    res.add_header("Content-Type", "application/json");
    if (gzip) {
      thread_local gzip_context compressor;
      if (!compressor.reset()) {
        res.internal_server_error_500();
        return;
      }
      auto& stream = compressor.stream;
      std::string compressed(deflateBound(&stream, body.size()), '\0');
      stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(body.data()));
      stream.avail_in = static_cast<uInt>(body.size());
      stream.next_out = reinterpret_cast<Bytef*>(compressed.data());
      stream.avail_out = static_cast<uInt>(compressed.size());
      const int result = deflate(&stream, Z_FINISH);
      if (result != Z_STREAM_END) {
        res.internal_server_error_500();
        return;
      }
      compressed.resize(stream.total_out);
      res.add_header("Content-Encoding", "gzip");
      res.set_body(compressed);
    } else {
      res.set_body(body);
    }
  };
  http_server.add_route("GET", "/json/:count", json_handler);
  martianlabs::doba::transport::tls_policies tls_configuration;
  tls_configuration.worker_count = workers;
  tls_configuration.ip = "0.0.0.0";
  tls_configuration.port = "8081";
  if (const char* configured = std::getenv("TLS_PORT")) {
    std::int64_t requested = 0;
    if (!parse_integer(configured, requested) || requested < 1 ||
        requested > 65535) {
      std::cerr << "TLS_PORT must be an integer from 1 to 65535\n";
      return 1;
    }
    tls_configuration.port = std::to_string(requested);
  }
  const char* certificate = std::getenv("TLS_CERT");
  const char* private_key = std::getenv("TLS_KEY");
  tls_configuration.certificate_file =
      certificate ? certificate : "/certs/server.crt";
  tls_configuration.private_key_file =
      private_key ? private_key : "/certs/server.key";
  martianlabs::doba::https_server<> tls_server(tls_configuration,
                                               http_configuration);
  tls_server.add_route("GET", "/json/:count", json_handler);
  // Let static_file_server validate and select files, including compressed
  // siblings. Share one cache budget across workers; do not preload files.
  const common::cache_policies cache_configuration;
  static_file_policies static_configuration;
  static_configuration.precompressed = true;
  static_configuration.cache =
      std::make_shared<static_file_cache>(cache_configuration);
  const char* static_path = std::getenv("STATIC_DIR");
  const std::filesystem::path static_root =
      static_path ? static_path : "/data/static";
  tls_server.add_controller<static_file_server>("/static", static_root,
                                                static_configuration);
  tls_server.add_route("POST", "/echo", [](const request& req, response& res) {
    res.ok_200();
    res.add_header("Content-Type", "application/octet-stream")
        .set_body(req.get_body_reader());
  });
#endif
  http_server.start();
#if DOBA_HTTPARENA_FULL
  tls_server.start();
  std::cerr << "workers per listener: " << workers << "; HTTP port: " << port
            << "; TLS port: " << tls_configuration.port << '\n';
#else
  std::cerr << "workers per listener: " << workers << "; HTTP port: " << port
            << "; TCP qualification build (not the full HttpArena image)\n";
#endif
  // The harness stops this process.
  std::promise<void> shutdown;
  shutdown.get_future().wait();
  return 0;
}
