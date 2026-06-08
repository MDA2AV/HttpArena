#include "handler.hpp"

#include <charconv>
#include <string>

#include <userver/components/component_context.hpp>
#include <userver/formats/json/value_builder.hpp>
#include <userver/http/common_headers.hpp>

#include <schemas/types.hpp>

#include "dataset_provider.hpp"

namespace userver_httparena::json {
Handler::Handler(const userver::components::ComponentConfig& config,
                 const userver::components::ComponentContext& context)
    : HttpHandlerBase(config, context), dataset_provider_{context.FindComponent<DatasetProvider>()} {}

std::string Handler::HandleRequestThrow(const userver::server::http::HttpRequest& request,
                                        userver::server::request::RequestContext&) const {
  const auto& count_str = request.GetPathArg("count");
  const auto& m_str = request.GetArg("m");

  auto count = 0;
  std::from_chars(count_str.data(), count_str.data() + count_str.size(), count);
  auto m = 1.0;
  if (!m_str.empty()) {
    std::from_chars(m_str.data(), m_str.data() + m_str.size(), m);
  }

  const auto& items = dataset_provider_.GetItems();
  if (count < 0) count = 0;
  if (static_cast<size_t>(count) > items.size()) {
    count = static_cast<int>(items.size());
  }

  JsonResponse resp;
  resp.count = count;
  resp.items.assign(items.begin(), items.begin() + count);
  for (auto& ri : resp.items) {
    ri.total = static_cast<double>(ri.price) * ri.quantity * m;
  }

  request.GetHttpResponse().SetHeader(userver::http::headers::kContentType, "application/json");
  return userver::formats::json::ToString(userver::formats::json::ValueBuilder{resp}.ExtractValue());
}
}  // namespace userver_httparena::json
