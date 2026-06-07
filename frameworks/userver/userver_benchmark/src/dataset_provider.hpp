#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include <userver/components/component_base.hpp>
#include <userver/yaml_config/schema.hpp>

namespace userver_httparena {
struct Item {
  int64_t id;
  std::string name;
  std::string category;
  int64_t price;
  int64_t quantity;
  bool active;
  std::vector<std::string> tags;

  struct {
    int64_t score;
    int64_t count;
  } rating;
};

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
