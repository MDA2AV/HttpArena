#include "handler.hpp"

#include <userver/http/common_headers.hpp>

namespace userver_httparena::plaintext {

const std::string kContentTypeTextPlain{"text/plain"};

std::string Handler::HandleRequestThrow(const userver::server::http::HttpRequest& request, userver::server::request::RequestContext&) const
{
    request.GetHttpResponse().SetHeader(userver::http::headers::kContentType, kContentTypeTextPlain);
    return GetResponse();
}

std::string Handler::GetResponse()
{ 
    return "ok";
}

}  // namespace userver_httparena::plaintext
