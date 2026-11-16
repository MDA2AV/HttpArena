// HttpArena entry for hidi: HTTP/2 over TLS on :8443 (baseline-h2, static-h2)
// and HTTP/2 cleartext with prior knowledge on :8082 (baseline-h2c).
#include <hidi/asio/ssl_context.hpp>
#include <hidi/h2server.hpp>

#include <sched.h>

#include <charconv>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>

namespace {

using file_data = std::shared_ptr<const std::string>;

// Files of /data/static as one thread sees them (h2server_mt creates a server
// per thread). A file is checked on disk at most every 100 ms
struct static_files {
  struct file {
    file_data data; // nullptr if there is no file
    std::filesystem::file_time_type mtime;
    std::chrono::steady_clock::time_point checked;
  };
  std::unordered_map<std::string, file> files;

  // nullptr if there is no such file. `remember_missing`: a missing file is
  // checked again only after 100 ms too (only for paths not taken from
  // requests, otherwise any request would grow the table)
  file_data get(const std::string &path, bool remember_missing) {
    auto now = std::chrono::steady_clock::now();
    auto [it, inserted] = files.try_emplace(path);
    file &f = it->second;
    if (!inserted && now - f.checked < std::chrono::milliseconds(100))
      return f.data;
    f.checked = now;
    std::error_code ec;
    auto mtime = std::filesystem::last_write_time(path, ec);
    if (ec) {
      if (remember_missing)
        f.data = nullptr;
      else
        files.erase(it);
      return nullptr;
    }
    if (!f.data || mtime != f.mtime) {
      std::ifstream in(path, std::ios::binary);
      f.data = std::make_shared<const std::string>(
          std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
      f.mtime = mtime;
    }
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

struct arena_server final : hidi::h2server {
  using hidi::h2server::h2server;

  static_files statics;

  hidi::http_response serve_static(std::string_view name,
                                   const hidi::http_request &r,
                                   hidi::request_context &ctx) {
    std::string path = "/data/static/" + std::string(name);
    file_data data = name.find('/') == name.npos
                         ? statics.get(path, /*remember_missing=*/false)
                         : nullptr;
    if (!data) {
      hidi::http_response rsp;
      rsp.status = 404;
      return rsp;
    }
    std::string_view accept_encoding;
    for (const hidi::http_header_t &h : r.headers)
      if (h.name() == "accept-encoding")
        accept_encoding = h.value();
    hidi::http_headers_t headers{
        {"content-type", std::string(content_type(name))}};
    // pre-compressed copies sit next to the file on disk
    const char *encoding = nullptr;
    if (accept_encoding.find("br") != accept_encoding.npos)
      if (file_data br = statics.get(path + ".br", /*remember_missing=*/true)) {
        data = std::move(br);
        encoding = "br";
      }
    if (!encoding && accept_encoding.find("gzip") != accept_encoding.npos)
      if (file_data gz = statics.get(path + ".gz", /*remember_missing=*/true)) {
        data = std::move(gz);
        encoding = "gzip";
      }
    if (encoding)
      headers.push_back({"content-encoding", encoding});
    return ctx.stream_response(200, std::move(headers), whole(std::move(data)));
  }

  dd::task<hidi::http_response>
  handle_request(hidi::http_request r, hidi::request_context ctx) override {
    hidi::http_response rsp;
    std::string_view path = r.path;
    std::string_view query;
    if (size_t q = path.find('?'); q != path.npos) {
      query = path.substr(q + 1);
      path = path.substr(0, q);
    }
    if (path.starts_with("/static/") && r.method == hidi::http_method_e::GET)
      co_return serve_static(path.substr(8), r, ctx);
    if (path != "/baseline2" || r.method != hidi::http_method_e::GET) {
      rsp.status = 404;
      co_return rsp;
    }
    // sum of all integer query parameter values
    int64_t sum = 0;
    while (!query.empty()) {
      size_t amp = query.find('&');
      std::string_view kv = query.substr(0, amp);
      query = amp == query.npos ? std::string_view{} : query.substr(amp + 1);
      size_t eq = kv.find('=');
      if (eq == kv.npos)
        continue;
      int64_t v = 0;
      auto [_, ec] =
          std::from_chars(kv.data() + eq + 1, kv.data() + kv.size(), v);
      if (ec == std::errc{})
        sum += v;
    }
    char buf[24];
    auto [end, _] = std::to_chars(buf, buf + sizeof(buf), sum);
    rsp.status = 200;
    rsp.headers.push_back({"content-type", "text/plain"});
    rsp.body.assign((hidi::byte_t *)buf, (hidi::byte_t *)end);
    co_return rsp;
  }
};

// CPUs this process may run on (respects the container cpuset), not every CPU
// of the host
size_t available_cpus() {
  cpu_set_t set;
  if (sched_getaffinity(0, sizeof(set), &set) == 0 && CPU_COUNT(&set) > 0)
    return size_t(CPU_COUNT(&set));
  return std::max(1u, std::thread::hardware_concurrency());
}

hidi::server_endpoint any_address(unsigned short port) {
  return hidi::server_endpoint{
      .addr = boost::asio::ip::tcp::endpoint(boost::asio::ip::address_v4::any(),
                                             port),
      .reuse_address = true,
  };
}

} // namespace

int main() try {
  const size_t threads = available_cpus();
  // many small frames per connection (responses to multiplexed requests): one
  // write per batch
  const hidi::tcp_connection_options tcp{.buffer_writes = true};

  // Only one profile runs at a time, so each server gets all available CPUs
  hidi::h2server_mt h2(threads, std::in_place_type<arena_server>,
                       hidi::make_ssl_context_for_server("/certs/server.crt",
                                                         "/certs/server.key"),
                       hidi::h2server_options{.tcp = tcp});
  hidi::h2server_mt h2c(threads, std::in_place_type<arena_server>, nullptr,
                        hidi::h2server_options{.tcp = tcp});

  std::thread tls_thread([&] {
    h2.listen(any_address(8443));
    h2.run();
  });
  h2c.listen(any_address(8082));
  std::cout << "hidi: h2 on :8443, h2c on :8082, threads: " << threads
            << std::endl;
  h2c.run();
  tls_thread.join();
} catch (std::exception &e) {
  std::cerr << "hidi: " << e.what() << std::endl;
  return 1;
}
