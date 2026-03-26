# frozen_string_literal: true

require 'zlib'
require 'pg'

class BenchmarkController < ActionController::API
  # Pre-load datasets at class level (shared across workers via preload)
  DATASET_PATH = ENV.fetch('DATASET_PATH', '/data/dataset.json')
  LARGE_DATASET_PATH = '/data/dataset-large.json'

  mattr_accessor :dataset_items, :db_available, :large_json_payload, :static_files_cache
  self.db_available = File.exist?('/data/benchmark.db')

  if File.exist?(DATASET_PATH)
    self.dataset_items = JSON.parse(File.read(DATASET_PATH))
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

  static_dir = '/data/static'
  if Dir.exist?(static_dir)
    cache = {}
    Dir.foreach(static_dir) do |name|
      next if name == '.' || name == '..'
      path = File.join(static_dir, name)
      next unless File.file?(path)
      ext = File.extname(name)
      ct = MIME_TYPES.fetch(ext, 'application/octet-stream')
      cache[name] = { data: File.binread(path), content_type: ct }
    end
    self.static_files_cache = cache
  else
    self.static_files_cache = {}
  end

  if File.exist?(LARGE_DATASET_PATH)
    raw = JSON.parse(File.read(LARGE_DATASET_PATH))
    items = raw.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
    self.large_json_payload = JSON.generate({ 'items' => items, 'count' => items.length })
  end

  DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'
  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50'

  def pipeline
    render plain: 'ok'
  end

  def baseline11
    total = 0
    request.query_parameters.each_value do |v|
      total += v.to_i
    end
    if request.post?
      body_str = request.body.read.to_s.strip
      total += body_str.to_i
    end
    render plain: total.to_s
  end

  def baseline2
    total = 0
    request.query_parameters.each_value do |v|
      total += v.to_i
    end
    render plain: total.to_s
  end

  def json_endpoint
    if dataset_items
      items = dataset_items.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
      body = JSON.generate({ 'items' => items, 'count' => items.length })
      response.headers['Content-Type'] = 'application/json'
      render plain: body
    else
      head 500
    end
  end

  def compression
    if large_json_payload
      sio = StringIO.new
      gz = Zlib::GzipWriter.new(sio, 1)
      gz.write(large_json_payload)
      gz.close
      response.headers['Content-Type'] = 'application/json'
      response.headers['Content-Encoding'] = 'gzip'
      send_data sio.string, disposition: :inline
    else
      head 500
    end
  end

  def db
    unless db_available
      render json: { items: [], count: 0 }
      return
    end

    min_val = (params[:min] || 10).to_f
    max_val = (params[:max] || 50).to_f
    conn = get_db
    rows = conn.execute(DB_QUERY, [min_val, max_val])
    items = rows.map do |r|
      {
        'id' => r['id'], 'name' => r['name'], 'category' => r['category'],
        'price' => r['price'], 'quantity' => r['quantity'], 'active' => r['active'] == 1,
        'tags' => JSON.parse(r['tags']),
        'rating' => { 'score' => r['rating_score'], 'count' => r['rating_count'] }
      }
    end
    render json: { items: items, count: items.length }
  end

  def async_db
    unless get_pg
      render json: { items: [], count: 0 }
      return
    end

    min_val = (params[:min] || 10.0).to_f
    max_val = (params[:max] || 50.0).to_f

    result = get_pg.with do |conn|
      conn.exec_params(PG_QUERY, [min_val, max_val])
    end
    items = result.map do |r|
      {
        'id' => r['id'].to_i, 'name' => r['name'], 'category' => r['category'],
        'price' => r['price'].to_f, 'quantity' => r['quantity'].to_i,
        'active' => r['active'] == 't',
        'tags' => JSON.parse(r['tags']),
        'rating' => { 'score' => r['rating_score'].to_f, 'count' => r['rating_count'].to_i }
      }
    end
    render json: { items: items, count: items.length }
  rescue PG::Error
    Thread.current[:pg_conn] = nil
    render json: { items: [], count: 0 }
  end

  def static_file
    filename = params[:filename]
    entry = static_files_cache[filename] if static_files_cache
    if entry
      send_data entry[:data], type: entry[:content_type], disposition: :inline
    else
      head 404
    end
  end

  def upload
    size = 0
    buf = request.body
    while (chunk = buf.read(65536))
      size += chunk.bytesize
    end
    render plain: size.to_s
  end

  def not_found
    head 404
  end

  private

  def get_db
    Thread.current[:rails_db] ||= begin
      db = SQLite3::Database.new('/data/benchmark.db', readonly: true)
      db.execute('PRAGMA mmap_size=268435456')
      db.results_as_hash = true
      db
    end
  end

  def get_pg
    return unless ENV['DATABASE_URL']
    Thread.current[:pg_conn] ||= ConnectionPool.new(size: 4, timeout: 5) do
      PG.connect(ENV['DATABASE_URL'])
    end
  end
end
