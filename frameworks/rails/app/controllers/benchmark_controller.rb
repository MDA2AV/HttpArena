# frozen_string_literal: true

require 'zlib'
require 'pg'

class BenchmarkController < ActionController::API
  mattr_accessor :dataset, :dataset_large, :database_path, :static_files_cache

  DATA_DIR = ENV.fetch('DATA_DIR', '/data')
  dataset_path = File.join(DATA_DIR, 'dataset.json')
  dataset_large_path = File.join(DATA_DIR, 'dataset-large.json')
  database_path = File.join(DATA_DIR, 'benchmark.db')
  static_dir = File.join(DATA_DIR, 'static')

  if File.exist?(dataset_path)
    self.dataset = JSON.parse(File.read(dataset_path))
  end

  if File.exist?(dataset_large_path)
    raw = JSON.parse(File.read(dataset_large_path))
    items = raw.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
    self.dataset_large = JSON.generate({ 'items' => items, 'count' => items.length })
  end

  if File.exist?(database_path)
    self.database_path = database_path
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

  self.static_files_cache = {}
  if File.exist?(static_dir)
    Dir.foreach(static_dir) do |name|
      next if name == '.' || name == '..'
      path = File.join(static_dir, name)
      next unless File.file?(path)
      ext = File.extname(name)
      ct = MIME_TYPES.fetch(ext, 'application/octet-stream')
      self.static_files_cache[name] = { data: File.binread(path), content_type: ct }
    end
  end

  DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'.freeze
  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50'.freeze

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
    if dataset
      items = dataset.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
      body = JSON.generate({ 'items' => items, 'count' => items.length })
      response.headers['Content-Type'] = 'application/json'
      render plain: body
    else
      head 500
    end
  end

  def compression
    accept_encodings = request.headers['Accept-Encoding'].split(',').map(&:strip)
    if accept_encodings.include? 'gzip'
      sio = StringIO.new
      gz = Zlib::GzipWriter.new(sio, 1)
      gz.write(self.class.dataset_large)
      gz.close
      response.headers['Content-Type'] = 'application/json'
      response.headers['Content-Encoding'] = 'gzip'
      send_data sio.string, disposition: :inline
    else
      render json: self.class.dataset_large
    end
  end

  def db
    min_val = (params[:min] || 10).to_i
    max_val = (params[:max] || 50).to_i

    rows = get_db&.execute(DB_QUERY, [min_val, max_val]) || []

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
    min_val = (params[:min] || 10).to_i
    max_val = (params[:max] || 50).to_i

    rows = get_pg&.exec_prepared('select', [min_val, max_val]) || []

    items = rows.map do |r|
      {
        'id' => r['id'].to_i, 'name' => r['name'], 'category' => r['category'],
        'price' => r['price'].to_f, 'quantity' => r['quantity'].to_i,
        'active' => r['active'] == 't',
        'tags' => JSON.parse(r['tags']),
        'rating' => { 'score' => r['rating_score'].to_f, 'count' => r['rating_count'].to_i }
      }
    end
    render json: { items: items, count: items.length }
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
      db = SQLite3::Database.new(self.class.database_path, readonly: true)
      db.execute('PRAGMA mmap_size=268435456')
      db.results_as_hash = true
      db
    rescue
      nil
    end
  end

  def get_pg
    Thread.current[:pg_conn] ||= begin
      db = PG.connect(ENV['DATABASE_URL'])
      db.prepare('select', PG_QUERY)
      db
    rescue
      nil
    end
  end
end
