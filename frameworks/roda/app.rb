# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

require 'zlib'

class Hash
  def symbolize_keys!
    transform_keys! { |key| key.to_sym }
  end
end

class App < Roda
  DATA_DIR = ENV.fetch('DATA_DIR', '/data')
  # Load dataset
  dataset_path = File.join DATA_DIR, 'dataset.json'
  if File.exist?(dataset_path)
    items = JSON.parse(File.read(dataset_path)).map do |item|
      item.symbolize_keys!
      item[:rating].symbolize_keys!
      item
    end
    opts[:dataset_items] = items
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

  plugin :public, root: DATA_DIR, gzip: true, brotli: true
  plugin :request_headers
  plugin :plain_hash_response_headers
  plugin :halt
  plugin :send_file
  plugin :all_verbs

  route do |r|
    r.root { 'ok' }

    r.is 'pipeline' do
      render_plain 'ok'
    end

    r.is('baseline11') do
      total = request.params['a'].to_i + request.params['b'].to_i
      if request.post?
        total += request.body.read.to_i
      end
      render_plain total.to_s
    end

    r.is 'baseline2' do
      total = request.params['a'].to_i + request.params['b'].to_i
      render_plain total.to_s
    end

    r.is 'json', Integer do |count|
      dataset = opts[:dataset_items]
      r.halt 500, 'No dataset' unless dataset
      m = (request.params['m'] || 1).to_i
      items = dataset.slice(0, count).map do |d|
        d.merge(total: (d[:price] * d[:quantity] * m))
      end

      render_json JSON.generate(items: items, count: count)
    end

    r.is 'upload' do
      request.env["puma.mark_as_io_bound"].call
      size = 0
      buf = request.body
      while (chunk = buf.read(65536))
        size += chunk.bytesize
      end
      size.to_s
    end

    r.is 'async-db' do
      min_val = (request.params['min'] || 10).to_i
      max_val = (request.params['max'] || 50).to_i
      limit = (request.params['limit'] || 50).to_i.clamp(1, 50)

      rows = self.class.get_async_db&.with do |connection|
        connection.exec_prepared('select', [min_val, max_val, limit])
      end || []

      items = rows.map do |row|
        map_row(row)
      end
      render_json JSON.generate({ items: items, count: items.length })
    end

    r.is 'crud/items' do
      r.get do
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

      r.post do
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
    end

    r.is 'crud/items', Integer do |id|
      r.get do
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
          r.halt 404, 'Not found'
        end
      end

      r.put do
        params = JSON.parse(request.body.read)
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
    end

    r.public
  end

  private

  def render_json(json)
    response[RodaResponseHeaders::CONTENT_TYPE] = 'application/json'
    json
  end

  def render_plain(plain)
    response[RodaResponseHeaders::CONTENT_TYPE] = 'text/plain'
    plain
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
