defmodule PhoenixBanditWeb.CrudController do
  use PhoenixBanditWeb, :controller

  @crud_columns "id, name, category, price, quantity, active, tags, rating_score, rating_count"

  @crud_list_sql "SELECT #{@crud_columns} FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3"
  @crud_get_sql "SELECT #{@crud_columns} FROM items WHERE id = $1 LIMIT 1"
  @crud_upsert_sql """
  INSERT INTO items
  (#{@crud_columns})
  VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0)
  ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5
  RETURNING #{@crud_columns}
  """
  @crud_update_sql """
  UPDATE items
  SET name = $1, price = $2, quantity = $3
  WHERE id = $4
  RETURNING #{@crud_columns}
  """

  def list(conn, params) do
    category = Map.get(params, "category", "electronics")
    page = params |> Map.get("page", "1") |> String.to_integer() |> max(1)
    limit = params |> Map.get("limit", "10") |> String.to_integer() |> max(1) |> min(50)

    offset = (page - 1) * limit

    case Postgrex.query(PhoenixBandit.DB.connection(), @crud_list_sql, [category, limit, offset]) do
      {:ok, %Postgrex.Result{rows: rows, num_rows: num_rows}} ->
        items = Enum.map(rows, &row_to_item/1)

        json(conn, %{items: items, total: num_rows, page: page, limit: limit})

      _error ->
        json(conn, %{items: [], total: 0, page: page, limit: limit})
    end
  end

  def show(conn, %{"id" => id}) do
    case :ets.lookup(:items_cache, id) do
      [{^id, cached_json}] ->
        conn
        |> put_resp_header("x-cache", " HIT")
        |> put_resp_content_type("application/json")
        |> send_resp(200, cached_json)

      [] ->
        case Postgrex.query(PhoenixBandit.DB.connection(), @crud_get_sql, [String.to_integer(id)]) do
          {:ok, %Postgrex.Result{rows: [row]}} ->
            item = row_to_item(row)
            encoded_json = Jason.encode!(item)

            :ets.insert(:items_cache, {id, encoded_json})

            conn
            |> put_resp_header("x-cache", " MISS")
            |> put_resp_content_type("application/json")
            |> send_resp(200, encoded_json)

          _error ->
            conn
            |> put_resp_header("x-cache", " MISS")
            |> send_resp(404, "")
        end
    end
  end

  def create(conn, params) do
    id = Map.get(params, "id")
    name = Map.get(params, "name", "New Product")
    category = Map.get(params, "category", "electronics")
    price = Map.get(params, "price", 0)
    quantity = Map.get(params, "quantity", 0)

    case Postgrex.query(PhoenixBandit.DB.connection(), @crud_upsert_sql, [
           id,
           name,
           category,
           price,
           quantity
         ]) do
      {:ok, %Postgrex.Result{rows: [row]}} ->
        :ets.delete(:items_cache, to_string(id))

        conn
        |> put_status(:created)
        |> json(row_to_item(row))

      _error ->
        send_resp(conn, 500, "")
    end
  end

  def update(conn, %{"id" => id} = params) do
    item_id = String.to_integer(id)
    name = Map.get(params, "name", "New Product")
    price = Map.get(params, "price")
    quantity = Map.get(params, "quantity")

    case Postgrex.query(PhoenixBandit.DB.connection(), @crud_update_sql, [
           name,
           price,
           quantity,
           item_id
         ]) do
      {:ok, %Postgrex.Result{rows: [row]}} ->
        :ets.delete(:items_cache, id)

        json(conn, row_to_item(row))

      {:ok, %Postgrex.Result{num_rows: 0}} ->
        send_resp(conn, 404, "")

      _error ->
        send_resp(conn, 404, "")
    end
  end

  @compile {:inline, row_to_item: 1}
  defp row_to_item([
         id,
         name,
         category,
         price,
         quantity,
         active,
         tags,
         rating_score,
         rating_count
       ]) do
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
  end
end
