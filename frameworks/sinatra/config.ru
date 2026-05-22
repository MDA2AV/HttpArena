require_relative 'app'

# Threads marked as IO bound are allowed to go over Puma's max thread limit.
class MarkAsIOBoundThreads
  def initialize(app)
    @app = app
  end

  def call(env)
    if env['PATH_INFO'].start_with? '/baseline'
      env["puma.mark_as_io_bound"].call
    end
    @app.call(env)
  end
end

use MarkAsIOBoundThreads
use Rack::Deflater
run App
