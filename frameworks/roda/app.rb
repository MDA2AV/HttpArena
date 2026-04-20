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
  SERVER_NAME = 'roda'.freeze

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

  plugin :public, root: DATA_DIR, gzip: true, brotli: true

  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3'.freeze

  plugin :default_headers, 'Server' => SERVER_NAME
  plugin :request_headers
  plugin :plain_hash_response_headers
  plugin :halt
  plugin :send_file

  route do |r|
    r.root { 'ok' }

    r.public

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

      result = JSON.generate({ 'items' => items, 'count' => count })

      if accept_encodings = r.headers['Accept-Encoding']
        type = accept_encodings.split(',').map(&:strip)
        if type.include? 'gzip'
          sio = StringIO.new
          gz = Zlib::GzipWriter.new(sio, 1)
          gz.write(result)
          gz.close
          response[RodaResponseHeaders::CONTENT_ENCODING] = 'gzip'
          result = sio.string
        end
      end
      render_json result
    end

    r.is 'upload' do
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
        {
          id: row['id'],
          name: row['name'],
          category: row['category'],
          price: row['price'],
          quantity: row['quantity'],
          active: row['active'] == 1,
          tags: JSON.parse(row['tags']),
          rating: { score: row['rating_score'], count: row['rating_count'] }
        }
      end
      render_json JSON.generate({ items: items, count: items.length })
    end
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

  def self.get_async_db
    @async_db ||= begin
      return unless ENV['DATABASE_URL']
      max_connections = ENV.fetch('MAX_THREADS', 4).to_i
      ConnectionPool.new(size: max_connections, timeout: 5) do
        db = PG.connect(ENV['DATABASE_URL'])
        db.prepare('select', PG_QUERY)
        db
      end
    end
  end
end
