#!/usr/bin/env -S falcon host
# frozen_string_literal: true

require "falcon/environment/rack"

service File.basename(__dir__) do
  include Falcon::Environment::Rack

  endpoint do
    Async::HTTP::Endpoint.parse("http://0.0.0.0:8080").with(
      protocol: Async::HTTP::Protocol::HTTP11
    )
  end
end
