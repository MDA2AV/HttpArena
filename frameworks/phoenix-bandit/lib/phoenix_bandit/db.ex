defmodule PhoenixBandit.DB do
  @name __MODULE__

  def connection do
    case Process.whereis(@name) do
      nil -> ensure_started()
      _pid -> @name
    end
  end

  defp ensure_started do
    child_spec = %{
      id: Postgrex,
      start: {Postgrex, :start_link, [db_opts()]}
    }

    case DynamicSupervisor.start_child(PhoenixBandit.DB.Supervisor, child_spec) do
      {:ok, _pid} -> @name
      {:error, {:already_started, _pid}} -> @name
      {:error, :already_present} -> @name
    end
  end

  defp db_opts do
    schedulers = System.schedulers_online()
    database_url = System.fetch_env!("DATABASE_URL")

    uri = URI.parse(database_url)
    [username, password] = String.split(uri.userinfo || ":", ":")

    pool_size =
      "DATABASE_MAX_CONN"
      |> System.get_env("256")
      |> String.to_integer()
      |> min(240)
      |> div(schedulers)
      |> max(1)

    [
      name: @name,
      hostname: uri.host,
      port: uri.port || 5432,
      username: username,
      password: password,
      database: String.trim_leading(uri.path || "", "/"),
      pool_size: pool_size
    ]
  end
end
