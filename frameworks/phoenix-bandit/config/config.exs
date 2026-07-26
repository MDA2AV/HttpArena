import Config

config :phoenix_bandit,
  generators: [timestamp_type: :utc_datetime]

config :phoenix_bandit, PhoenixBanditWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: PhoenixBanditWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PhoenixBandit.PubSub,
  live_view: [signing_salt: "sUys6q4D"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

env_config = "#{config_env()}.exs"

if File.exists?(Path.join(__DIR__, env_config)) do
  import_config env_config
end
