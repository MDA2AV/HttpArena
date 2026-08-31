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

  post "/echo" do
    {body, conn} = read_body_all(conn, [])

    conn
    |> put_resp_content_type("application/octet-stream", nil)
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, "")
  end

  # Collects the body a chunk at a time and hands back the accumulated iodata.
  # read_body/2 decodes chunked framing itself, so nothing here reads
  # content-length - a chunked request has none - and send_resp/3 takes iodata
  # and derives content-length from it, zero included for an empty body.
  defp read_body_all(conn, acc) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} -> {Enum.reverse([chunk | acc]), conn}
      {:more, chunk, conn} -> read_body_all(conn, [chunk | acc])
      {:error, _reason} -> {Enum.reverse(acc), conn}
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
