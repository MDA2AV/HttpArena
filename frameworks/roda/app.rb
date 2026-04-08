# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

require 'zlib'

class App < Roda
  SERVER_NAME = 'roda'.freeze

  DATA_DIR = ENV.fetch('DATA_DIR', '/data')
  # Load dataset
  dataset_path = File.join DATA_DIR, 'dataset.json'
  if File.exist?(dataset_path)
    opts[:dataset_items] = JSON.parse(File.read(dataset_path))
  end

  # Large dataset for compression
  dataset_large_path = File.join DATA_DIR, 'dataset-large.json'
  if File.exist?(dataset_large_path)
    raw = JSON.parse(File.read(dataset_large_path))
    items = raw.map do |d|
      d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0)
    end
    opts[:large_json_payload] = JSON.generate({ 'items' => items, 'count' => items.length })
  end

  # Load static files into memory
  MIME_TYPES = {
    '.css'   => 'text/css',
    '.js'    => 'application/javascript',
    '.html'  => 'text/html',
    '.woff2' => 'font/woff2',
    '.svg'   => 'image/svg+xml',
    '.webp'  => 'image/webp',
    '.json'  => 'application/json'
  }.freeze

  static_dir = File.join DATA_DIR, 'static'
  opts[:static_files_cache] = {}
  if Dir.exist?(static_dir)
    Dir.foreach(static_dir) do |name|
      next if name == '.' || name == '..'
      path = File.join(static_dir, name)
      next unless File.file?(path)
      ext = File.extname(name)
      ct = MIME_TYPES.fetch(ext, 'application/octet-stream')
      opts[:static_files_cache][name] = { data: File.binread(path), content_type: ct }
    end
  end
  opts[:static_files_cache].freeze

  # SQLite
  opts[:database_path] = File.join(DATA_DIR, 'benchmark.db').freeze

  DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'.freeze
  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50'.freeze

  plugin :default_headers, 'Server' => SERVER_NAME
  plugin :halt
  plugin :request_headers

  route do |r|
    r.root { 'ok' }

    r.is 'pipeline' do
      response[RodaResponseHeaders::CONTENT_TYPE] = 'text/plain'
      'ok'
    end

    r.is('baseline11') { handle_baseline11 }

    r.is 'baseline2' do
      total = 0
      request.GET.each do |_k, v|
        total += v.to_i
      end
      response[RodaResponseHeaders::CONTENT_TYPE] = 'text/plain'
      total.to_s
    end

    r.is 'json' do
      dataset = opts[:dataset_items]
      r.halt 500, 'No dataset' unless dataset
      items = dataset.map do |d|
        d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0)
      end
      response[RodaResponseHeaders::CONTENT_TYPE] = 'application/json'
      JSON.generate({ 'items' => items, 'count' => items.length })
    end

    r.is 'compression' do
      payload = opts[:large_json_payload]
      r.halt 500, 'No dataset' unless payload
      accept_encodings = r.headers['Accept-Encoding'].split(',').map(&:strip)
      if accept_encodings.include? 'gzip'
        sio = StringIO.new
        gz = Zlib::GzipWriter.new(sio, 1)
        gz.write(payload)
        gz.close
        response[RodaResponseHeaders::CONTENT_TYPE] = 'application/json'
        response[RodaResponseHeaders::CONTENT_ENCODING] = 'gzip'
        sio.string
      else
        payload
      end
    end

    r.is 'upload' do
      size = 0
      buf = request.body
      while (chunk = buf.read(65536))
        size += chunk.bytesize
      end
      size.to_s
    end

    r.is 'db' do
      min_val = (request.params['min'] || 10).to_i
      max_val = (request.params['max'] || 50).to_i

      rows = self.class.get_db&.with do |connection|
        connection.execute(DB_QUERY, [min_val, max_val])
      end || []

      items = rows.map do |row|
        {
          'id' => row['id'], 'name' => row['name'], 'category' => row['category'],
          'price' => row['price'], 'quantity' => row['quantity'], 'active' => row['active'] == 1,
          'tags' => JSON.parse(row['tags']),
          'rating' => { 'score' => row['rating_score'], 'count' => row['rating_count'] }
        }
      end
      response[RodaResponseHeaders::CONTENT_TYPE] = 'application/json'
      JSON.generate({ 'items' => items, 'count' => items.length })
    end

    r.is 'async-db' do
      min_val = (request.params['min'] || 10).to_i
      max_val = (request.params['max'] || 50).to_i

      rows = self.class.get_async_db&.with do |connection|
        connection.exec_prepared('select', [min_val, max_val])
      end || []

      items = rows.map do |row|
        {
          'id' => row['id'], 'name' => row['name'], 'category' => row['category'],
          'price' => row['price'], 'quantity' => row['quantity'], 'active' => row['active'] == 1,
          'tags' => JSON.parse(row['tags']),
          'rating' => { 'score' => row['rating_score'], 'count' => row['rating_count'] }
        }
      end
      response[RodaResponseHeaders::CONTENT_TYPE] = 'application/json'
      JSON.generate({ 'items' => items, 'count' => items.length })
    end

    r.on 'static', String do |filename|
      if entry = opts[:static_files_cache][filename]
        response[RodaResponseHeaders::CONTENT_TYPE] = entry[:content_type]
        entry[:data]
      else
        r.halt 404
      end
    end
  end

  def handle_baseline11
    total = 0
    request.GET.each do |_k, v|
      total += v.to_i
    end
    if request.post?
      request.body.rewind
      body_str = request.body.read.strip
      total += body_str.to_i
    end
    response[RodaResponseHeaders::CONTENT_TYPE] = 'text/plain'
    total.to_s
  end

  private

  def self.get_db
    @db ||= begin
      return unless opts[:database_path]
      max_connections = ENV.fetch('MAX_THREADS', 4).to_i
      ConnectionPool.new(size: max_connections, timeout: 5) do
        db = SQLite3::Database.new(opts[:database_path], readonly: true)
        db.execute('PRAGMA mmap_size=268435456')
        db.results_as_hash = true
        db
      end
    end
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
