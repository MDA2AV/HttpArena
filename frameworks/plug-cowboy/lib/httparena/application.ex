defmodule HttpArena.Application do
  use Application

  @impl true
  def start(_type, _args) do
    dataset =
      case File.read(System.get_env("DATASET_PATH") || "/data/dataset.json") do
        {:ok, body} -> Jason.decode!(body)
        _ -> []
      end

    :persistent_term.put(:dataset, dataset)

    children = [
      {Plug.Cowboy,
       scheme: :http,
       plug: HttpArena.Router,
       options: [
         port: 8080,
         # adds cowboy_compress_h, which answers Accept-Encoding for json-comp
         compress: true,
         protocol_options: [
           max_keepalive: :infinity,
           idle_timeout: :infinity
         ],
         transport_options: [
           num_acceptors: System.schedulers_online() * 2,
           max_connections: :infinity
         ]
       ]}
    ] ++ tls_child()

    Supervisor.start_link(children, strategy: :one_for_one, name: HttpArena.Supervisor)
  end

  # json-tls on 8081: a second Plug.Cowboy listener in front of the same router,
  # so both ports run the identical plug pipeline. Plug.Cowboy derives its ref
  # from plug + scheme, so the two children do not collide. The harness only
  # mounts /certs for the TLS profiles, so without them only 8080 comes up.
  defp tls_child do
    cert = "/certs/server.crt"
    key = "/certs/server.key"

    if File.exists?(cert) and File.exists?(key) do
      [
        {Plug.Cowboy,
         scheme: :https,
         plug: HttpArena.Router,
         options: [
           port: 8081,
           certfile: cert,
           keyfile: key,
           compress: true,
           protocol_options: [
             max_keepalive: :infinity,
             idle_timeout: :infinity
           ],
           transport_options: [
             num_acceptors: System.schedulers_online() * 2,
             max_connections: :infinity
           ]
         ]}
      ]
    else
      []
    end
  end
end
