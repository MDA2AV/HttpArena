#pragma once

#include <userver/server/handlers/http_handler_base.hpp>

#include <cstdint>

namespace userver_httparena {
class DatasetProvider;

namespace json {
class Handler final : public userver::server::handlers::HttpHandlerBase {
 public:
  static constexpr std::string_view kName = "json-handler";

  Handler(const userver::components::ComponentConfig& config, const userver::components::ComponentContext& context);

  std::string HandleRequestThrow(const userver::server::http::HttpRequest& request,
                                 userver::server::request::RequestContext&) const final;

 private:
  const DatasetProvider& dataset_provider_;
};
}  // namespace json
}  // namespace userver_httparena
