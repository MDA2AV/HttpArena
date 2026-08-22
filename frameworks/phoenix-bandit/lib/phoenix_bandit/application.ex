defmodule PhoenixBandit.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    load_dataset()
    init_items_ets_cache()

    children = [
      {DNSCluster, query: Application.get_env(:phoenix_bandit, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PhoenixBandit.PubSub},
      # Start a worker by calling: PhoenixBandit.Worker.start_link(arg)
      # {PhoenixBandit.Worker, arg},
      # Start to serve requests, typically the last entry
      {DynamicSupervisor, strategy: :one_for_one, name: PhoenixBandit.DB.Supervisor},
      PhoenixBanditWeb.Endpoint
    ] ++ json_tls_child()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixBandit.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # json-tls needs HTTP/1.1 over TLS on 8081. The endpoint's own https: config
  # already holds 8443 for the h2 profiles and Phoenix binds one https listener
  # per endpoint, so this is a second Bandit listener in front of the same
  # endpoint plug -- the identical pipeline, not a copy of it. The harness only
  # mounts /certs for the TLS profiles, so without them the child is not added.
  defp json_tls_child do
    cert = System.get_env("TLS_CERT_PATH", "/certs/server.crt")
    key = System.get_env("TLS_KEY_PATH", "/certs/server.key")

    if File.exists?(cert) and File.exists?(key) do
      [
        Supervisor.child_spec(
          {Bandit,
           plug: PhoenixBanditWeb.Endpoint,
           scheme: :https,
           port: 8081,
           ip: {0, 0, 0, 0},
           thousand_island_options: [
             num_acceptors: 100,
             transport_options: [certfile: Path.expand(cert), keyfile: Path.expand(key)]
           ]},
          id: :json_tls_listener
        )
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PhoenixBanditWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp load_dataset do
    data_dir = System.get_env("DATA_DIR", "/data")
    dataset_path = Path.expand(Path.join(data_dir, "dataset.json"))

    dataset_items =
      case File.read(dataset_path) do
        {:ok, contents} ->
          Jason.decode!(contents)

        {:error, reason} ->
          IO.puts("Failed to read dataset at #{dataset_path}: #{inspect(reason)}")
          []
      end

    :persistent_term.put(:benchmark_dataset, dataset_items)
  end

  defp init_items_ets_cache do
    :ets.new(:items_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])
  end
end
