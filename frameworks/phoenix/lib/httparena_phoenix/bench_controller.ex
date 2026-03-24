defmodule HttparenaPhoenix.BenchController do
  use Phoenix.Controller

  import Plug.Conn

  @db_query "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ?1 AND ?2 LIMIT 50"

  def pipeline(conn, _params) do
    conn
    |> put_resp_header("server", "phoenix")
    |> put_resp_header("content-type", "text/plain")
    |> send_resp(200, "ok")
  end

  def baseline11(conn, params) do
    query_sum = sum_query_params(params)

    body_val =
      case conn.method do
        "POST" ->
          {:ok, body, _conn} = read_body(conn)
          case Integer.parse(String.trim(body)) do
            {n, _} -> n
            :error -> 0
          end
        _ -> 0
      end

    total = query_sum + body_val

    conn
    |> put_resp_header("server", "phoenix")
    |> put_resp_header("content-type", "text/plain")
    |> send_resp(200, Integer.to_string(total))
  end

  def baseline2(conn, params) do
    total = sum_query_params(params)

    conn
    |> put_resp_header("server", "phoenix")
    |> put_resp_header("content-type", "text/plain")
    |> send_resp(200, Integer.to_string(total))
  end

  def json(conn, _params) do
    dataset = :persistent_term.get(:dataset)
    items = Enum.map(dataset, fn d ->
      total = Float.round(d["price"] * d["quantity"] * 1.0, 2)
      Map.put(d, "total", total)
    end)
    body = Jason.encode!(%{"items" => items, "count" => length(items)})

    conn
    |> put_resp_header("server", "phoenix")
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, body)
  end

  def compression(conn, _params) do
    large_dataset = :persistent_term.get(:large_dataset)
    items = Enum.map(large_dataset, fn d ->
      total = Float.round(d["price"] * d["quantity"] * 1.0, 2)
      Map.put(d, "total", total)
    end)
    body = Jason.encode!(%{"items" => items, "count" => length(items)})
    compressed = :zlib.gzip(body)

    conn
    |> put_resp_header("server", "phoenix")
    |> put_resp_header("content-encoding", "gzip")
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, compressed)
  end

  def upload(conn, _params) do
    {:ok, body, conn} = read_body(conn, length: 25_000_000)
    size = byte_size(body)

    conn
    |> put_resp_header("server", "phoenix")
    |> put_resp_header("content-type", "text/plain")
    |> send_resp(200, Integer.to_string(size))
  end

  def db(conn, params) do
    db_available = :persistent_term.get(:db_available)

    unless db_available do
      conn
      |> put_resp_header("server", "phoenix")
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, ~s({"items":[],"count":0}))
    else
      min_val = parse_float(params["min"], 10.0)
      max_val = parse_float(params["max"], 50.0)

      {:ok, db_conn} = Exqlite.Sqlite3.open("/data/benchmark.db", [:readonly])
      :ok = Exqlite.Sqlite3.execute(db_conn, "PRAGMA mmap_size=268435456")
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db_conn, @db_query)
      :ok = Exqlite.Sqlite3.bind(stmt, [min_val, max_val])

      rows = fetch_all_rows(db_conn, stmt, [])
      :ok = Exqlite.Sqlite3.release(db_conn, stmt)
      :ok = Exqlite.Sqlite3.close(db_conn)

      items = Enum.map(rows, fn [id, name, category, price, quantity, active, tags_str, rating_score, rating_count] ->
        tags = case Jason.decode(tags_str) do
          {:ok, t} when is_list(t) -> t
          _ -> []
        end

        %{
          "id" => id,
          "name" => name,
          "category" => category,
          "price" => price,
          "quantity" => quantity,
          "active" => active != 0,
          "tags" => tags,
          "rating" => %{"score" => rating_score, "count" => rating_count}
        }
      end)

      body = Jason.encode!(%{"items" => items, "count" => length(items)})

      conn
      |> put_resp_header("server", "phoenix")
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, body)
    end
  end

  def static_file(conn, %{"filename" => filename}) do
    static_files = :persistent_term.get(:static_files)

    case Map.get(static_files, filename) do
      nil ->
        conn
        |> put_resp_header("server", "phoenix")
        |> send_resp(404, "Not Found")

      %{data: data, content_type: ct} ->
        conn
        |> put_resp_header("server", "phoenix")
        |> put_resp_header("content-type", ct)
        |> send_resp(200, data)
    end
  end

  # Helpers

  defp sum_query_params(params) do
    params
    |> Enum.reduce(0, fn
      {"filename", _v}, acc -> acc
      {_k, v}, acc ->
        case Integer.parse(v) do
          {n, ""} -> acc + n
          _ -> acc
        end
    end)
  end

  defp parse_float(nil, default), do: default
  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error ->
        case Integer.parse(val) do
          {i, _} -> i * 1.0
          :error -> default
        end
    end
  end
  defp parse_float(_, default), do: default

  defp fetch_all_rows(db_conn, stmt, acc) do
    case Exqlite.Sqlite3.step(db_conn, stmt) do
      {:row, row} -> fetch_all_rows(db_conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
