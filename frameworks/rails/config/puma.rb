thread_count = ENV.fetch('RAILS_MAX_THREADS', 4).to_i
threads thread_count, thread_count

tls_cert_path = ENV.fetch('TLS_CERT', '/certs/server.crt')
tls_key_path = ENV.fetch('TLS_KEY', '/certs/server.key')
bind "tcp://0.0.0.0:8080"
bind "ssl://0.0.0.0:8081?cert=#{tls_cert_path}&key=#{tls_key_path}"

# Allow all HTTP methods so Rack middleware can return 405 instead of Puma returning 501
supported_http_methods :any

preload_app!

before_fork do
  # Close any inherited DB connections
end
