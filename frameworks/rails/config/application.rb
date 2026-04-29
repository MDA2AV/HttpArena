# frozen_string_literal: true

require 'rails'
require 'action_controller/railtie'

Bundler.require(*Rails.groups)

class BenchmarkApp < Rails::Application
  config.load_defaults Rails::VERSION::STRING.to_f
  config.eager_load = true
  config.enable_reloading = false
  config.api_only = true
  config.secret_key_base = 'benchmark-not-secret'
  config.hosts.clear

  config.action_dispatch.default_headers = {'Server' => 'Rails'}

  config.consider_all_requests_local = false

  # Disable all middleware we don't need
  config.middleware.delete ActionDispatch::HostAuthorization
  config.middleware.delete ActionDispatch::Callbacks
  config.middleware.delete ActionDispatch::RemoteIp
  config.middleware.delete ActionDispatch::RequestId
  config.middleware.delete Rails::Rack::Logger
  config.middleware.delete ActionDispatch::ShowExceptions

  # Add gzip support
  config.middleware.insert 0, Rack::Deflater

  # Catch unknown HTTP methods, routing errors, and mark /upload as binary
  config.middleware.insert 0, Class.new {
    VALID_METHODS = %w[GET HEAD POST PUT DELETE PATCH OPTIONS TRACE].to_set.freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      unless VALID_METHODS.include?(env['REQUEST_METHOD'])
        return [405, { 'content-type' => 'text/plain' }, ['Method Not Allowed']]
      end
      # Mark /upload as binary so Rack skips form parameter parsing
      if env['PATH_INFO'] == '/upload'
        env['CONTENT_TYPE'] = 'application/octet-stream'
      end
      @app.call(env)
    rescue => e
      if e.class.name.include?('UnknownHttpMethod') || e.class.name.include?('RoutingError')
        [400, { 'content-type' => 'text/plain' }, ['Bad Request']]
      else
        raise
      end
    end
  }

  # Silence logging
  config.logger = nil
  config.log_level = :fatal
end
