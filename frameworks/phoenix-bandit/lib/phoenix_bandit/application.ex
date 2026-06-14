defmodule PhoenixBandit.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ets.new(:items_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    children = [
      {DNSCluster, query: Application.get_env(:phoenix_bandit, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PhoenixBandit.PubSub},
      # Start a worker by calling: PhoenixBandit.Worker.start_link(arg)
      # {PhoenixBandit.Worker, arg},
      # Start to serve requests, typically the last entry
      {DynamicSupervisor, strategy: :one_for_one, name: PhoenixBandit.DB.Supervisor},
      PhoenixBanditWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PhoenixBandit.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PhoenixBanditWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
