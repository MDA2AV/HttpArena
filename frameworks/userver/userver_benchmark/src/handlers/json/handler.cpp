#include "handler.hpp"

#include <charconv>
#include <string>

#include <userver/components/component_config.hpp>
#include <userver/components/component_context.hpp>
#include <userver/formats/json/string_builder.hpp>
#include <userver/http/common_headers.hpp>

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

  userver::formats::json::StringBuilder sb;
  {
    userver::formats::json::StringBuilder::ObjectGuard root_guard(sb);
    sb.Key("count");
    sb.WriteInt64(count);
    sb.Key("items");
    {
      userver::formats::json::StringBuilder::ArrayGuard items_guard(sb);
      for (int i = 0; i < count; ++i) {
        const auto& item = items[i];
        userver::formats::json::StringBuilder::ObjectGuard item_guard(sb);
        sb.Key("id");
        sb.WriteInt64(item.id);
        sb.Key("price");
        sb.WriteInt64(item.price);
        sb.Key("quantity");
        sb.WriteInt64(item.quantity);
        sb.Key("total");
        sb.WriteDouble(static_cast<double>(item.price) * item.quantity * m);
      }
    }
  }

  request.GetHttpResponse().SetHeader(userver::http::headers::kContentType, "application/json");
  return sb.GetString();
}
}  // namespace userver_httparena::json
