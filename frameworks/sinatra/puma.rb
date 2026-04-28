threads ENV.fetch('MAX_THREADS', 4).to_i

tls_cert_path = ENV.fetch('TLS_CERT', '/certs/server.crt')
tls_key_path = ENV.fetch('TLS_KEY', '/certs/server.key')
bind "tcp://0.0.0.0:8080"
bind "ssl://0.0.0.0:8081?cert=#{tls_cert_path}&key=#{tls_key_path}"

# Allow all HTTP methods so unknown ones reach Rack middleware (returned as 405)
supported_http_methods :any

preload_app!

before_fork do
  # Close any inherited DB connections
end
