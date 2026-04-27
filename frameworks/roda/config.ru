require_relative 'app'

# Rack middleware to handle unknown HTTP methods before Puma/Sinatra
class MethodGuard
  KNOWN = %w[GET POST PUT DELETE PATCH HEAD OPTIONS TRACE CONNECT].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    if KNOWN.include?(env['REQUEST_METHOD'])
      @app.call(env)
    else
      [405, { 'content-type' => 'text/plain', 'server' => 'roda' }, ['Method Not Allowed']]
    end
  end
end

# Threads marked as IO bound are allowed to go over Puma's max thread limit.
class MarkAsIOBoundThreads
  def initialize(app)
    @app = app
  end

  def call(env)
    if env['PATH_INFO'] == '/baseline'
      env["puma.mark_as_io_bound"].call
    end
    @app.call(env)
  end
end

use MarkAsIOBoundThreads
use MethodGuard
use Rack::Deflater # enable gzip
run App
