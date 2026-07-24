import Config

if System.get_env("PHX_SERVER") do
  config :phoenix_bandit, PhoenixBanditWeb.Endpoint, server: true
end

config :phoenix_bandit, PhoenixBanditWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "8080"))]

if config_env() == :prod do
  host = System.get_env("PHX_HOST") || "example.com"

  https_port = String.to_integer(System.get_env("HTTPS_PORT", "8443"))

  cert_path = System.get_env("TLS_CERT_PATH", "/certs/server.crt")
  key_path = System.get_env("TLS_KEY_PATH", "/certs/server.key")

  config :phoenix_bandit, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :phoenix_bandit, PhoenixBanditWeb.Endpoint,
    url: [host: host, port: https_port, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      thousand_island_options: [num_acceptors: 100]
    ],
    https: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: https_port,
      cipher_suite: :strong,
      certfile: Path.expand(cert_path),
      keyfile: Path.expand(key_path),
      thousand_island_options: [num_acceptors: 100]
    ],
    server: true
end
