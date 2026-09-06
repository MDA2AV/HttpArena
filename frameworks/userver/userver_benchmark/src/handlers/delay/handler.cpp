#include "handler.hpp"

#include <charconv>
#include <chrono>

#include <userver/engine/sleep.hpp>
#include <userver/http/common_headers.hpp>

namespace userver_httparena::delay {
const std::string kContentTypeTextPlain{"text/plain"};

std::string Handler::HandleRequestThrow(const userver::server::http::HttpRequest& request,
                                        userver::server::request::RequestContext&) const {
  const auto& ms_str = request.GetPathArg("ms");

  auto ms = 0;
  std::from_chars(ms_str.data(), ms_str.data() + ms_str.size(), ms);
  if (ms < 0) ms = 0;

  // SleepFor suspends the coroutine and hands its task processor thread back, so the waits in
  // flight are bounded by memory rather than by the size of the task processor.
  if (ms > 0) {
    userver::engine::SleepFor(std::chrono::milliseconds{ms});
  }

  request.GetHttpResponse().SetHeader(userver::http::headers::kContentType, kContentTypeTextPlain);
  return std::to_string(ms);
}
}  // namespace userver_httparena::delay
