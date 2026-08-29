#include "handler.hpp"

#include <userver/http/common_headers.hpp>

namespace userver_httparena::echo {
std::string Handler::HandleRequestThrow(const userver::server::http::HttpRequest& request,
                                        userver::server::request::RequestContext&) const {
  // RequestBody() is the body the server already decoded, chunked framing
  // included, so nothing here looks at Content-Length: a chunked request has
  // none. Returning the string is what frames the response -- userver sets
  // Content-Length from its size, zero included.
  request.GetHttpResponse().SetHeader(userver::http::headers::kContentType, "application/octet-stream");
  return request.RequestBody();
}
}  // namespace userver_httparena::echo
