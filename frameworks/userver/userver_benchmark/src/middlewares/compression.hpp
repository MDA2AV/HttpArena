#pragma once

#include <string_view>

#include <userver/server/middlewares/http_middleware_base.hpp>

namespace userver_httparena::middlewares {
class CompressionMiddleware final : public userver::server::middlewares::HttpMiddlewareBase {
 public:
  static constexpr std::string_view kName = "compression-middleware";

  explicit CompressionMiddleware(const userver::server::handlers::HttpHandlerBase&);

  void HandleRequest(userver::server::http::HttpRequest& request,
                     userver::server::request::RequestContext& context) const final;
};
}  // namespace userver_httparena::middlewares
