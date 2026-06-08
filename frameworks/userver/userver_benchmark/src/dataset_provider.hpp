#pragma once

#include <vector>

#include <userver/components/component_base.hpp>
#include <userver/yaml_config/schema.hpp>

#include <schemas/types.hpp>

namespace userver_httparena {
class DatasetProvider final : public userver::components::ComponentBase {
 public:
  static constexpr std::string_view kName = "dataset-provider";

  DatasetProvider(const userver::components::ComponentConfig& config,
                  const userver::components::ComponentContext& context);

  static constexpr auto kConfigFileMode = userver::components::ConfigFileMode::kNotRequired;

  static userver::yaml_config::Schema GetStaticConfigSchema();

  const std::vector<Item>& GetItems() const { return items_; }

 private:
  std::vector<Item> items_;
};
}  // namespace userver_httparena
