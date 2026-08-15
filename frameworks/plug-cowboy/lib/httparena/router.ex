defmodule HttpArena.Router do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/pipeline" do
    send_text(conn, "ok")
  end

  match "/baseline11", via: [:get, :post] do
    conn = fetch_query_params(conn)

    sum =
      conn.query_params
      |> Map.values()
      |> Enum.reduce(0, fn value, acc -> acc + to_int(value) end)

    if conn.method == "POST" do
      {:ok, body, conn} = read_body(conn)
      send_text(conn, Integer.to_string(sum + to_int(body)))
    else
      send_text(conn, Integer.to_string(sum))
    end
  end

  get "/json/:count" do
    conn = fetch_query_params(conn)
    dataset = :persistent_term.get(:dataset, [])
    count = count |> to_int() |> max(0) |> min(length(dataset))

    m =
      case conn.query_params["m"] do
        nil -> 1
        value -> to_int(value)
      end

    items =
      dataset
      |> Enum.take(count)
      |> Enum.map(fn item ->
        Map.put(item, "total", item["price"] * item["quantity"] * m)
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{items: items, count: count}))
  end

  post "/upload" do
    {size, conn} = body_size(conn, 0)
    send_text(conn, Integer.to_string(size))
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp body_size(conn, acc) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} -> {acc + byte_size(chunk), conn}
      {:more, chunk, conn} -> body_size(conn, acc + byte_size(chunk))
      {:error, _reason} -> {acc, conn}
    end
  end

  defp send_text(conn, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  defp to_int(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp to_int(_value), do: 0
end
