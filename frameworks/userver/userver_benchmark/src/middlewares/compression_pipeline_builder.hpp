#pragma once

#include <userver/server/middlewares/configuration.hpp>

#include "middlewares/compression.hpp"

namespace userver_httparena::middlewares {
class CompressionPipelineBuilder final : public userver::server::middlewares::HandlerPipelineBuilder {
 public:
  static constexpr std::string_view kName = "compression-pipeline-builder";

  using HandlerPipelineBuilder::HandlerPipelineBuilder;

  userver::server::middlewares::MiddlewaresList BuildPipeline(
      userver::server::middlewares::MiddlewaresList pipeline) const override {
    pipeline.emplace_back(CompressionMiddleware::kName);
    return pipeline;
  }
};
}  // namespace userver_httparena::middlewares
