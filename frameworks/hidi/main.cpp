// HttpArena entry for hidi: HTTP/2 over TLS on :8443 (baseline-h2, static-h2)
// and HTTP/2 cleartext with prior knowledge on :8082 (baseline-h2c).
#include <hidi/asio/io.hpp>
#include <hidi/asio/ssl_context.hpp>
#include <hidi/h2server.hpp>

#include <boost/asio/io_context.hpp>

#include <pthread.h>
#include <sched.h>

#include <charconv>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

using file_data = std::shared_ptr<const std::string>;

// The disk is checked at most every 100 ms, a clock with a few ms resolution is
// enough for that, and it is several times cheaper than steady_clock
std::chrono::nanoseconds coarse_now() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC_COARSE, &t);
  return std::chrono::seconds(t.tv_sec) + std::chrono::nanoseconds(t.tv_nsec);
}

// Files of /data/static as one thread sees them (h2server_mt creates a server
// per thread). A file is checked on disk at most every 100 ms
struct static_files {
  struct file {
    file_data data; // nullptr if there is no file
    std::filesystem::file_time_type mtime;
    std::chrono::nanoseconds checked;
  };
  std::unordered_map<std::string, file> files;

  // nullptr if there is no such file. `remember_missing`: a missing file is
  // checked again only after 100 ms too (only for paths not taken from
  // requests, otherwise any request would grow the table)
  file_data get(const std::string &path, bool remember_missing,
                std::chrono::nanoseconds now) {
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

// Event loops shared by the TLS and h2c servers: server i of both runs on loop
// i, one thread per loop. A loop runs only on its thread, so asio does not wake
// other threads for its handlers
struct arena_loops {
  std::deque<boost::asio::io_context> ctxs;
  size_t next = 0;

  explicit arena_loops(size_t count) {
    for (size_t i = 0; i < count; ++i)
      ctxs.emplace_back(/*concurrency_hint=*/1);
  }
  // h2server_mt constructs its servers one by one, server 0 runs on the
  // calling thread
  boost::asio::io_context &take() { return ctxs[next++ % ctxs.size()]; }
};

struct arena_server final : hidi::h2server {
  arena_server(hidi::server_ssl_context_ptr ssl, arena_loops &loops)
      : hidi::h2server(std::move(ssl), {},
                       hidi::make_asio_io_context(loops.take())) {}

  static_files statics;

  hidi::http_response serve_static(std::string_view name,
                                   const hidi::http_request &r,
                                   hidi::request_context &ctx) {
    std::string path = "/data/static/" + std::string(name);
    auto now = coarse_now();
    file_data data = name.find('/') == name.npos
                         ? statics.get(path, /*remember_missing=*/false, now)
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
      if (file_data br =
              statics.get(path + ".br", /*remember_missing=*/true, now)) {
        data = std::move(br);
        encoding = "br";
      }
    if (!encoding && accept_encoding.find("gzip") != accept_encoding.npos)
      if (file_data gz =
              statics.get(path + ".gz", /*remember_missing=*/true, now)) {
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
std::vector<int> available_cpus() {
  std::vector<int> cpus;
  cpu_set_t set;
  if (sched_getaffinity(0, sizeof(set), &set) == 0)
    for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu)
      if (CPU_ISSET(cpu, &set))
        cpus.push_back(cpu);
  if (cpus.empty())
    for (int cpu = 0;
         cpu < int(std::max(1u, std::thread::hardware_concurrency())); ++cpu)
      cpus.push_back(cpu);
  return cpus;
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
  const std::vector<int> cpus = available_cpus();
  const size_t threads = cpus.size();

  arena_loops loops(threads);
  hidi::h2server_mt h2(threads, std::in_place_type<arena_server>,
                       hidi::make_ssl_context_for_server("/certs/server.crt",
                                                         "/certs/server.key"),
                       loops);
  hidi::h2server_mt h2c(threads, std::in_place_type<arena_server>, nullptr,
                        loops);
  h2.listen(any_address(8443));
  h2c.listen(any_address(8082));
  std::cout << "hidi: h2 on :8443, h2c on :8082, threads: " << threads
            << std::endl;
  // the loops are shared, so running them for h2 serves h2c too
  h2.run();
} catch (std::exception &e) {
  std::cerr << "hidi: " << e.what() << std::endl;
  return 1;
}
