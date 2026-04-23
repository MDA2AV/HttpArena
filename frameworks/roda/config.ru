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

use MethodGuard
use Rack::Deflater # enable gzip
run App
