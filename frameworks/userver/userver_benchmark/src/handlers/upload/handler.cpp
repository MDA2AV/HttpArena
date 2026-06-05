#include "handler.hpp"

#include <userver/http/common_headers.hpp>

namespace userver_httparena::upload {
std::string Handler::HandleRequestThrow(const userver::server::http::HttpRequest& request,
                                        userver::server::request::RequestContext&) const {
  const auto& body = request.RequestBody();
  request.GetHttpResponse().SetHeader(userver::http::headers::kContentType, "text/plain");
  return std::to_string(body.size());
}
}  // namespace userver_httparena::upload
