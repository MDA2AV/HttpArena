thread_count = ENV.fetch('RAILS_MAX_THREADS', 4).to_i
threads thread_count, thread_count

bind 'tcp://0.0.0.0:8080'

# Allow all HTTP methods so Rack middleware can return 405 instead of Puma returning 501
supported_http_methods :any

preload_app!

before_fork do
  # Close any inherited DB connections
end
