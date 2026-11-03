// HttpArena entry for hidi: HTTP/2 over TLS on :8443 (baseline-h2) and HTTP/2
// cleartext with prior knowledge on :8082 (baseline-h2c).
#include <hidi/asio/ssl_context.hpp>
#include <hidi/h2server.hpp>

#include <sched.h>

#include <charconv>
#include <cstdint>
#include <iostream>
#include <optional>
#include <string_view>
#include <thread>

namespace {

struct arena_server final : hidi::h2server {
  using hidi::h2server::h2server;

  dd::task<hidi::http_response> handle_request(hidi::http_request r,
                                               hidi::request_context) override {
    hidi::http_response rsp;
    std::string_view path = r.path;
    std::string_view query;
    if (size_t q = path.find('?'); q != path.npos) {
      query = path.substr(q + 1);
      path = path.substr(0, q);
    }
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
