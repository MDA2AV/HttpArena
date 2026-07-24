Symbol.alias_method(:to_s, :name)

require 'rails'
require 'action_controller/railtie'

Bundler.require(*Rails.groups)

# Mark /upload as binary so Rack skips form parameter parsing
class MarkUploadAsBinary
  def initialize(app)
    @app = app
  end

  def call(env)
    if env['PATH_INFO'] == '/upload'
      env['CONTENT_TYPE'] = 'application/octet-stream'
    end
    @app.call(env)
  end
end

# Threads marked as IO bound are allowed to go over Puma's max thread limit.
class MarkAsIOBoundThreads
  IOBoundPaths = %w[/baseline11 /baseline2 /async-db].map { [_1, nil] }.to_h.freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    if IOBoundPaths.has_key? env['PATH_INFO']
      env["puma.mark_as_io_bound"].call
    end
    @app.call(env)
  end
end

class BenchmarkApp < Rails::Application
  config.load_defaults Rails::VERSION::STRING.to_f
  config.eager_load = true
  config.enable_reloading = false
  config.api_only = true
  config.secret_key_base = 'benchmark-not-secret'
  config.hosts.clear

  config.action_dispatch.default_headers = {}

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
  config.middleware.insert 0, MarkUploadAsBinary
  config.middleware.insert 0, MarkAsIOBoundThreads

  # Silence logging
  config.logger = nil
  config.log_level = :fatal
end
