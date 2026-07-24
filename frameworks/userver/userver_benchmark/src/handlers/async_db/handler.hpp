#pragma once

#include <userver/server/handlers/http_handler_base.hpp>
#include <userver/storages/postgres/postgres_fwd.hpp>

namespace userver_httparena::async_db {
class Handler final : public userver::server::handlers::HttpHandlerBase {
 public:
  static constexpr std::string_view kName = "async-db-handler";

  Handler(const userver::components::ComponentConfig& config, const userver::components::ComponentContext& context);

  std::string HandleRequestThrow(const userver::server::http::HttpRequest& request,
                                 userver::server::request::RequestContext&) const final;

 private:
  const userver::storages::postgres::ClusterPtr pg_;
};
}  // namespace userver_httparena::async_db
