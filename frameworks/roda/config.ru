require_relative 'app'

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

use MarkAsIOBoundThreads
use Rack::Deflater # enable gzip
run App
