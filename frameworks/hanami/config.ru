require "hanami/boot"
require "rack"

# The benchmark posts plain and binary bodies. Rack parses a body with no
# Content-Type as form data, so form parsing is limited to real form types.
Rack::Request::Helpers.module_eval do
  FORM_MEDIA_TYPES = ["application/x-www-form-urlencoded", "multipart/form-data"].freeze

  def form_data?
    FORM_MEDIA_TYPES.include?(media_type)
  end

  def parseable_data?
    false
  end
end

# hanami-router parses every request body as a query string unless someone
# already parsed it, which the 20 MB upload cannot afford. The flag it looks at
# is the same one its body parser middleware sets.
class SkipRouterBodyParsing
  PARSED_BODY = "router.parsed_body".freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    env[PARSED_BODY] = nil unless env.key?(PARSED_BODY)
    @app.call(env)
  end
end

use SkipRouterBodyParsing
use Rack::Deflater
run Hanami.app
