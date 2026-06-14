defmodule PhoenixBanditWeb.BenchmarkController do
  use PhoenixBanditWeb, :controller

  @data_dir System.get_env("DATA_DIR", "/data")

  def pipeline(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  def baseline_get(conn, params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Integer.to_string(sum_params(params)))
  end

  def baseline_post(conn, params) do
    {:ok, body, _conn} = read_body(conn)

    body_value = if body == "", do: 0, else: String.to_integer(body)

    total = sum_params(params) + body_value

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, Integer.to_string(total))
  end

  def json_count(conn, %{"count" => count} = params) do
    case load_dataset() do
      {:ok, dataset} ->
        count = count |> String.to_integer() |> clamp_int(0, length(dataset))
        m = params |> Map.get("m", "1") |> String.to_integer()

        result = %{
          count: count,
          items:
            dataset
            |> Enum.take(count)
            |> Enum.map(fn d ->
              %{
                id: d["id"],
                name: d["name"],
                category: d["category"],
                price: d["price"],
                quantity: d["quantity"],
                active: d["active"],
                tags: d["tags"],
                rating: d["rating"],
                total: d["price"] * d["quantity"] * m
              }
            end)
        }

        respond_dataset(conn, result)

      {:error, _reason} ->
        send_resp(conn, 500, "dataset not found")
    end
  end

  def async_db(conn, params) do
    min_val = params |> Map.get("min", "10") |> String.to_integer()
    max_val = params |> Map.get("max", "50") |> String.to_integer()

    limit =
      params
      |> Map.get("limit", "50")
      |> String.to_integer()
      |> clamp_int(1, 100)

    sql = """
    SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
    FROM items
    WHERE price BETWEEN $1 AND $2
    LIMIT $3
    """

    case Postgrex.query(PhoenixBandit.DB.connection(), sql, [min_val, max_val, limit]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        items =
          Enum.map(rows, fn [
                              id,
                              name,
                              category,
                              price,
                              quantity,
                              active,
                              tags,
                              rating_score,
                              rating_count
                            ] ->
            %{
              id: id,
              name: name,
              category: category,
              price: price,
              quantity: quantity,
              active: active,
              tags: tags,
              rating: %{
                score: rating_score,
                count: rating_count
              }
            }
          end)

        json(conn, %{count: length(items), items: items})

      _ ->
        json(conn, %{count: 0, items: []})
    end
  end

  def upload(conn, _params) do
    size = read_body_chunks(conn, 0)

    conn
    |> put_resp_header("server", "Phoenix")
    |> put_resp_content_type("text/plain")
    |> send_resp(200, to_string(size))
  end

  def ws(conn, _params) do
    try do
      conn
      |> WebSockAdapter.upgrade(PhoenixBanditWeb.EchoWebSocket, nil, timeout: 60_000)
      |> halt()
    rescue
      _exception ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(400, "Upgrade failed")
        |> halt()
    end
  end

  defp sum_params(params) do
    Enum.reduce(Map.values(params), 0, fn value, acc ->
      acc + String.to_integer(value)
    end)
  end

  defp clamp_int(v, min, max), do: v |> max(min) |> min(max)

  defp respond_dataset(conn, result) do
    payload = Jason.encode!(result)

    case get_req_header(conn, "accept-encoding") do
      [encoding | _] ->
        type =
          encoding |> String.split(",", parts: 2) |> hd()

        conn = put_resp_content_type(conn, "application/json")

        cond do
          # Gzip compression is automatically handled by Bandit

          type == "br" ->
            case :brotli.encode(payload) do
              {:ok, compressed} ->
                conn
                |> put_resp_header("content-encoding", "br")
                |> send_resp(200, compressed)

              _ ->
                send_resp(conn, 200, payload)
            end

          true ->
            send_resp(conn, 200, payload)
        end

      _ ->
        json(conn, result)
    end
  end

  defp load_dataset do
    dataset_path = Path.expand(Path.join(@data_dir, "dataset.json"))

    with {:ok, contents} <- File.read(dataset_path),
         {:ok, dataset} <- Jason.decode(contents) do
      {:ok, dataset}
    else
      {:error, _} -> {:error, :not_found}
    end
  end

  defp read_body_chunks(conn, acc_size) do
    case read_body(conn) do
      {:ok, binary, _conn} ->
        acc_size + byte_size(binary)

      {:more, binary, conn} ->
        read_body_chunks(conn, acc_size + byte_size(binary))
    end
  end
end
