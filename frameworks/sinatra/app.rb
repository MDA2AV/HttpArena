# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

require 'pg'

class Hash
  def symbolize_keys!
    transform_keys! { |key| key.to_sym }
  end
end

module Sinatra
  class Request < Rack::Request
    # Rack::Request sees the body of a POST request without content-type set as form data.
    # This breaks the upload test.
    def form_data?
      FORM_DATA_MEDIA_TYPES.include?(media_type)
    end
  end
end

class App < Sinatra::Base
  configure do
    set :server, :puma
    set :logging, nil
    set :show_exceptions, false

    # Disable unused protections
    disable :protection
    set :host_authorization, { permitted_hosts: [] }

    # Set root once instead executing the proc on every request
    set :root, File.expand_path(__dir__)

    # Load dataset
    DATA_DIR = ENV.fetch('DATA_DIR', '/data')
    dataset_path = File.join DATA_DIR, 'dataset.json'
    if File.exist?(dataset_path)
      items = JSON.parse(File.read(dataset_path)).map do |item|
        item.symbolize_keys!
        item[:rating].symbolize_keys!
        item
      end
      set :dataset_items, items.freeze
    else
      set :dataset_items, nil
    end

    set :static, true
    set :public_folder, DATA_DIR
  end

  CRUD_COLUMNS = 'id, name, category, price, quantity, active, tags, rating_score, rating_count'
  SELECT_QUERY = "SELECT #{CRUD_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3".freeze
  CRUD_GET_SQL =  "SELECT #{CRUD_COLUMNS} FROM items WHERE id = $1 LIMIT 1"
  CRUD_LIST_SQL = "SELECT #{CRUD_COLUMNS} FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3"
  CRUD_UPDATE_SQL = "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4"
  CRUD_UPSERT_SQL = <<~SQL
    INSERT INTO items
    (#{CRUD_COLUMNS})
    VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0)
    ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5
    RETURNING id
  SQL

  get '/pipeline' do
    render_plain 'ok'
  end

  get('/baseline11') do
    total = 0
    request.GET.each do |_k, v|
      total += v.to_i
    end
    render_plain total.to_s
  end

  post('/baseline11') do
    total = params['a'].to_i + params['b'].to_i
    total += request.body.read.to_i
    render_plain total.to_s
  end

  get '/baseline2' do
    total = params['a'].to_i + params['b'].to_i
    render_plain total.to_s
  end

  get '/json/:count' do
    dataset = settings.dataset_items
    halt 500, 'No dataset' unless dataset
    count = params['count'].to_i
    m = (request.params['m'] || 1).to_i

    items = dataset.slice(0, count).map do |d|
      d.merge(total: (d[:price] * d[:quantity] * m))
    end

    render_json JSON.generate(items: items, count: items.length)
  end

  post '/upload' do
    size = 0
    buf = request.body
    while (chunk = buf.read(65536))
      size += chunk.bytesize
    end
    render_plain size.to_s
  end

  get '/async-db' do
    min_val = (params['min'] || 10).to_i
    max_val = (params['max'] || 50).to_i
    limit = (params['limit'] || 50).to_i.clamp(1, 50)

    rows = self.class.get_async_db&.with do |connection|
      connection.exec_prepared('select', [min_val, max_val, limit])
    end || []

    items = rows.map do |row|
      map_row(row)
    end
    render_json JSON.generate(items: items, count: items.length)
  end

  get '/crud/items' do
    category = request.params['category'] || 'electronics'
    page = (request.params['page'] || 1).to_i
    limit = (request.params['limit'] || 10).to_i
    offset = (page - 1) * limit

    rows = self.class.get_async_db&.with do |connection|
      connection.exec_prepared('crud_list', [category, limit, offset])
    end || []

    items = rows.map do |row|
      map_row(row)
    end
    render_json JSON.generate({ items: items, total: items.length, page: page, limit: limit })
  end

  get '/crud/items/:id' do
    id = params['id']
    json = self.class.redis&.with do |connection|
      connection.get(id.to_s)
    end
    if json
      response['x-cache'] = 'HIT'
      return render_json json
    else
      response['x-cache'] = 'MISS'
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
      render_json json
    else
      not_found
    end
  end

  post '/crud/items' do
    params = JSON.parse(request.body.read)
    id = params['id']
    name = params['name'] || 'New Product'
    category = params['category'] || 'electronics'
    price = (params['price'] || 0).to_i
    quantity = (params['quantity'] || 0).to_i

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

    response.status = 201
    render_json JSON.generate(item)
  end

  put '/crud/items/:id' do
    id = params['id']
    name = params['name'] || 'New Product'
    price = (params['price'] || 0).to_i
    quantity = (params['quantity'] || 0).to_i

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
    render_json JSON.generate(item)
  end
  private

  def render_json(json)
    headers 'content-type' => 'application/json'
    json
  end

  def render_plain(text)
    headers 'content-type' => 'text/plain'
    text
  end

  def map_row(row)
    mapped_row = {
      id: row[:id],
      name: row[:name],
      category: row[:category],
      price: row[:price],
      quantity: row[:quantity],
      active: row[:active] == 1,
    }
    mapped_row[:tags] = JSON.parse(row[:tags]) if row[:tags]
    mapped_row[:rating] = { score: row[:rating_score], count: row[:rating_count] } if row[:rating_score] && row[:rating_count]
    mapped_row
  end

  def self.get_async_db
    @async_db ||= begin
      return unless ENV['DATABASE_URL']
      ConnectionPool.new(size: pool_size, timeout: 5) do
        db = PG.connect(ENV['DATABASE_URL'])
        db.field_name_type = :symbol
        db.prepare('select', SELECT_QUERY)
        db.prepare('crud_get', CRUD_GET_SQL)
        db.prepare('crud_list', CRUD_LIST_SQL)
        db.prepare('crud_update', CRUD_UPDATE_SQL)
        db.prepare('crud_upsert', CRUD_UPSERT_SQL)
        db
      end
    end
  end

  def self.redis
    @redis ||= begin
      return unless ENV['REDIS_URL']
      ConnectionPool::Wrapper.new(size: pool_size, timeout: 10) do
        Redis.new(url: ENV['REDIS_URL'])
      end
    end
  end

  def self.pool_size
    ENV.fetch('MAX_THREADS', 4).to_i + ENV.fetch("MAX_IO_THREADS", 10).to_i
  end
end
