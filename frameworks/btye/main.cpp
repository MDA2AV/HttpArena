// HttpArena entry for BT-YE: HTTP/2 over TLS on :8443 (baseline-h2, static-h2)
// and HTTP/2 cleartext with prior knowledge on :8082 (baseline-h2c, json-h2c).
// The API is described in arena.yaml, the server is generated from it by svarg
#include <btye/app.hpp>
#include <btye/mt_server.hpp>
#include <hidi/asio/ssl_context.hpp>
#include <svarg/backend/cxx/support/json_stream.hpp>

#include "arena/server.hpp"

#include <sched.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <print>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace {

using arena::components::schemas::Item;
using svarg::cxx_support::make_response;

// /data/dataset.json, parsed once
const std::vector<Item> &dataset() {
  static const std::vector<Item> items = [] {
    std::ifstream file("/data/dataset.json", std::ios::binary);
    std::string text(std::istreambuf_iterator<char>(file), {});
    return svarg::from_json_string<std::vector<Item>>(text);
  }();
  return items;
}

using file_data = std::shared_ptr<const std::string>;

// Files of /data/static as one actor sees them. A cached file is checked on
// disk again when it is older than 100 ms, so a replaced file is noticed
struct static_files {
  struct file {
    file_data data; // nullptr if there is no file
    std::filesystem::file_time_type mtime;
    std::chrono::steady_clock::time_point checked;
  };
  std::unordered_map<std::string, file> files;

  file_data get(const std::string &path) {
    auto now = std::chrono::steady_clock::now();
    auto [it, inserted] = files.try_emplace(path);
    file &f = it->second;
    if (!inserted && now - f.checked < std::chrono::milliseconds(100))
      return f.data;
    f.checked = now;
    std::error_code ec;
    auto mtime = std::filesystem::last_write_time(path, ec);
    if (ec) {
      f.data = nullptr;
      return nullptr;
    }
    if (f.data && mtime == f.mtime)
      return f.data;
    std::ifstream in(path, std::ios::binary);
    if (!in) {
      f.data = nullptr;
      return nullptr;
    }
    f.mtime = mtime;
    f.data = std::make_shared<const std::string>(
        std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    return f.data;
  }
};

std::string_view content_type(std::string_view name) {
  std::string_view ext = name.substr(name.rfind('.') + 1);
  if (ext == "css")
    return "text/css";
  if (ext == "js")
    return "application/javascript";
  if (ext == "html")
    return "text/html";
  if (ext == "json")
    return "application/json";
  if (ext == "svg")
    return "image/svg+xml";
  if (ext == "webp")
    return "image/webp";
  if (ext == "woff2")
    return "font/woff2";
  return "application/octet-stream";
}

// `data` stays alive and unchanged while it is written
hidi::streaming_body_t whole(file_data data) {
  co_yield hidi::chunk(*data, /*stable=*/true, /*end_stream=*/true);
}

std::string_view header_value(const hidi::http_request &r,
                              std::string_view name) {
  for (const hidi::http_header_t &h : r.headers)
    if (h.name() == name)
      return h.value();
  return {};
}

struct arena_server : arena::server {
  using arena::server::server;

  static_files statics;

  btye::task<hidi::http_response> handle(arena::baseline op, hidi::http_request,
                                         hidi::request_context) override {
    co_return make_response(
        arena::baseline::response_200{.body = op.query.a + op.query.b});
  }

  btye::task<hidi::http_response> handle(arena::getJson op, hidi::http_request,
                                         hidi::request_context) override {
    const std::vector<Item> &items = dataset();
    size_t count =
        std::min<size_t>(std::max<int64_t>(op.path.count, 0), items.size());
    arena::getJson::response_200 rsp;
    rsp.body.count = int64_t(count);
    rsp.body.items.assign(items.begin(), items.begin() + count);
    for (Item &i : rsp.body.items)
      i.total = i.price * i.quantity * op.query.m;
    co_return make_response(std::move(rsp));
  }

  btye::task<hidi::http_response> handle(arena::getStatic op,
                                         hidi::http_request r,
                                         hidi::request_context ctx) override {
    const std::string &name = op.path.filename;
    std::string path = "/data/static/" + name;
    file_data data = name.find('/') == name.npos ? statics.get(path) : nullptr;
    if (!data)
      co_return make_response(arena::getStatic::response_404{});
    hidi::http_headers_t headers{
        {"content-type", std::string(content_type(name))}};
    // pre-compressed copies sit next to the file on disk
    std::string_view accept_encoding = header_value(r, "accept-encoding");
    for (std::string_view encoding : {"br", "gzip"}) {
      if (accept_encoding.find(encoding) == accept_encoding.npos)
        continue;
      std::string_view suffix = encoding == "br" ? ".br" : ".gz";
      if (file_data compressed = statics.get(path + std::string(suffix))) {
        data = std::move(compressed);
        headers.push_back({"content-encoding", std::string(encoding)});
        break;
      }
    }
    co_return ctx.stream_response(200, std::move(headers),
                                  whole(std::move(data)));
  }
};

// CPUs this process may run on (respects the container cpuset)
size_t available_cpus() {
  cpu_set_t set;
  if (sched_getaffinity(0, sizeof(set), &set) == 0 && CPU_COUNT(&set) > 0)
    return CPU_COUNT(&set);
  return 0; // btye: one actor per hardware thread
}

} // namespace

int main() {
  dataset(); // fails at start rather than on the first request
  return btye::run({.actors_count = available_cpus()}, []() -> btye::task<int> {
    btye::mt_server<arena_server> h2;
    btye::mt_server<arena_server> h2c;
    co_await h2.start(hidi::make_ssl_context_for_server("/certs/server.crt",
                                                        "/certs/server.key"));
    co_await h2c.start();
    h2.listen_home({.addr = {boost::asio::ip::address_v4::any(), 8443}});
    h2c.listen_home({.addr = {boost::asio::ip::address_v4::any(), 8082}});
    std::println("btye: h2 on :8443, h2c on :8082");
    co_await btye::wait_stopped();
    co_return 0;
  });
}
