#include "handler.hpp"

#include <userver/http/common_headers.hpp>

namespace userver_httparena::baseline11 {

const std::string kContentTypeTextPlain{"text/plain"};

std::string Handler::HandleRequestThrow(const userver::server::http::HttpRequest& request, userver::server::request::RequestContext&) const
{
    const auto & a = request.GetArg("a");
    const auto & b = request.GetArg("b");
    std::string body;
    if (request.GetMethod() == userver::server::http::HttpMethod::kPost) {
        body = request.RequestBody();
    }    
    request.GetHttpResponse().SetHeader(userver::http::headers::kContentType, kContentTypeTextPlain);
    return GetResponse(a, b, body);
}

std::string Handler::GetResponse(const std::string& a, const std::string& b, const std::string& body)
{ 
    int sum = std::stoi(a) + std::stoi(b);
    if (!body.empty()) {
        sum += std::stoi(body);
    }
    return std::to_string(sum);
}

}  // namespace userver_httparena::baseline11
