#include "dataset_provider.hpp"

#include <userver/components/component_config.hpp>
#include <userver/components/component_context.hpp>
#include <userver/formats/json/serialize.hpp>
#include <userver/formats/json/value.hpp>
#include <userver/yaml_config/merge_schemas.hpp>

namespace userver_httparena {
namespace {
Item ParseItem(const userver::formats::json::Value& item_json) {
  Item item;
  item.id = item_json["id"].As<int64_t>();
  item.name = item_json["name"].As<std::string>();
  item.category = item_json["category"].As<std::string>();
  item.price = item_json["price"].As<int64_t>();
  item.quantity = item_json["quantity"].As<int64_t>();
  item.active = item_json["active"].As<bool>();
  for (const auto& tag : item_json["tags"]) {
    item.tags.push_back(tag.As<std::string>());
  }
  item.rating.score = item_json["rating"]["score"].As<int64_t>();
  item.rating.count = item_json["rating"]["count"].As<int64_t>();
  return item;
}
}  // namespace

DatasetProvider::DatasetProvider(const userver::components::ComponentConfig& config,
                                 const userver::components::ComponentContext& context)
    : ComponentBase(config, context) {
  const auto path = config["dataset-path"].As<std::string>();
  const auto doc = userver::formats::json::blocking::FromFile(path);
  for (const auto& item_json : doc) {
    items_.push_back(ParseItem(item_json));
  }
}

userver::yaml_config::Schema DatasetProvider::GetStaticConfigSchema() {
  return userver::yaml_config::MergeSchemas<userver::components::ComponentBase>(
      R"(
type: object
description: Dataset provider component
additionalProperties: false
properties:
    dataset-path:
        type: string
        description: path to the JSON dataset file
)");
}
}  // namespace userver_httparena
