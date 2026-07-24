class ItemsController < ApplicationController
  def index
    category = params[:category] || 'electronics'
    page = (params[:page] || 1).to_i
    limit = (params[:limit] || 10).to_i
    offset = (page - 1) * limit

    rows = self.class.get_async_db&.with do |connection|
      connection.exec_prepared('crud_list', [category, limit, offset])
    end || []

    items = rows.map do |row|
      map_row(row)
    end
    render json: { items: items, total: items.length, page: page, limit: limit }
  end

  def show
    id = params[:id]
    json = self.class.redis&.with do |connection|
      connection.get(id.to_s)
    end
    if json
      headers['x-cache'] = ' HIT'
      return render json: json
    else
      headers['x-cache'] = ' MISS'
    end

    rows = self.class.get_async_db&.with do |connection|
      connection.exec_prepared('crud_get', [id])
    end || []

    if row = rows.first
      item = map_row(row)
      json = JSON.generate(item)
      self.class.redis&.with do |connection|
        connection.set(id.to_s, json)
      end
      render json: item
    else
      head 404
    end
  end

  def create
    id = params[:id]
    name = params[:name] || 'New Product'
    category = params[:category] || 'electronics'
    price = (params[:price] || 0).to_i
    quantity = (params[:quantity] || 0).to_i

    self.class.get_async_db&.with do |connection|
      connection.exec_prepared('crud_upsert', [id, name, category, price, quantity])
    end

    self.class.redis&.with do |connection|
      connection.del(id.to_s)
    end

    item = {
      'id' => id,
      'name' => name,
      'category' => category,
      'price' => price,
      'quantity' => quantity
    }

    render json: item, status: 201
  end

  def update
    id = params[:id]
    name = params[:name] || 'New Product'
    price = (params[:price] || 0).to_i
    quantity = (params[:quantity] || 0).to_i

    row = self.class.get_async_db&.with do |connection|
      connection.exec_prepared('crud_update', [name, price, quantity, id])
    end || []

    self.class.redis&.with do |connection|
      connection.del(id.to_s)
    end

    item = {
      'id' => id,
      'name' => name,
      'price' => price,
      'quantity' => quantity
    }
    render json: item
  end

  private

  def map_row(row)
    mapped_row = {
      id: row[:id],
      name: row[:name],
      category: row[:category],
      price: row[:price],
      quantity: row[:quantity],
      active: row[:active] == 1,
    }
    mapped_row[:tags] = JSON.parse(row[:tags]) if row.has_key?(:tags)
    mapped_row[:rating] = { score: row[:rating_score], count: row[:rating_count] } if row.has_key?(:rating_score) && row.has_key?(:rating_count)
    mapped_row
  end
end
