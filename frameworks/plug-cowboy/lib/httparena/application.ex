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
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: HttpArena.Supervisor)
  end
end
