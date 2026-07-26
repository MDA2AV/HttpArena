#include "handler.hpp"

#include <charconv>

#include <userver/http/common_headers.hpp>

namespace userver_httparena::baseline2 {
std::string Handler::HandleRequestThrow(const userver::server::http::HttpRequest& request,
                                        userver::server::request::RequestContext&) const {
  const auto& a = request.GetArg("a");
  const auto& b = request.GetArg("b");

  int sum = 0, b_val = 0;
  std::from_chars(a.data(), a.data() + a.size(), sum);
  std::from_chars(b.data(), b.data() + b.size(), b_val);
  sum += b_val;

  request.GetHttpResponse().SetHeader(userver::http::headers::kContentType, "text/plain");
  return std::to_string(sum);
}
}  // namespace userver_httparena::baseline2
