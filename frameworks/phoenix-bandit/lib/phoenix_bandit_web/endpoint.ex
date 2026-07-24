defmodule PhoenixBanditWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :phoenix_bandit

  plug Plug.Static,
    at: "/static",
    from: Path.join(Path.expand(System.get_env("DATA_DIR", "/data"), File.cwd!()), "static"),
    gzip: not code_reloading?,
    brotli: not code_reloading?,
    raise_on_missing_only: code_reloading?

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug PhoenixBanditWeb.Router
end
