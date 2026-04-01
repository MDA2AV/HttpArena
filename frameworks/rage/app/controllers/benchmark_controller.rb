# frozen_string_literal: true

require 'zlib'

class BenchmarkController < RageController::API
  DATA_DIR = ENV.fetch('DATA_DIR', '/data')

  dataset_path = File.join DATA_DIR, 'dataset.json'
  if File.exist?(dataset_path)
    @dataset_items = JSON.parse(File.read(dataset_path))
  end

  dataset_large_path = File.join DATA_DIR, 'dataset-large.json'
  if File.exist?(dataset_large_path)
    raw = JSON.parse(File.read(dataset_large_path))
    items = raw.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
    @large_json_payload = JSON.generate({ 'items' => items, 'count' => items.length })
  end

  @database_path = File.join DATA_DIR, 'benchmark.db'

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
  @static_files_cache = {}
  if Dir.exist?(static_dir)
    Dir.foreach(static_dir) do |name|
      next if name == '.' || name == '..'
      path = File.join(static_dir, name)
      next unless File.file?(path)
      ext = File.extname(name)
      ct = MIME_TYPES.fetch(ext, 'application/octet-stream')
      @static_files_cache[name] = { data: File.binread(path), content_type: ct }
    end
  end

  DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'
  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50'

  def self.database_path = @database_path
  def self.large_json_payload = @large_json_payload
  def self.dataset_items = @dataset_items
  def self.static_files_cache = @static_files_cache

  before_action do
    headers["server"] = "rage"
  end

  def pipeline
    render plain: 'ok'
  end

  def baseline_one
    total = 0
    params.each_value do |v|
      total += v.to_i
    end
    if request.post?
      rack_input = request.send(:rack_request).env["rack.input"]
      rack_input.rewind
      body_str = rack_input.read.strip
      total += body_str.to_i
    end
    render plain: total.to_s
  end

  def baseline_two
    total = 0
    params.each_value do |v|
      total += v.to_i
    end
    render plain: total.to_s
  end

  def json_endpoint
    if self.class.dataset_items
      items = self.class.dataset_items.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
    else
      items = []
    end
    render json: { 'items' => items, 'count' => items.length }
  end

  def compression
    if self.class.large_json_payload
      accept_encodings = request.headers['Accept-Encoding'].split(',').map(&:strip)
      if accept_encodings.include? 'gzip'
        sio = StringIO.new
        gz = Zlib::GzipWriter.new(sio, 1)
        gz.write(self.class.large_json_payload)
        gz.close
        headers['Content-Encoding'] = 'gzip'
        headers['Content-Type'] = 'application/json'
        render plain: sio.string
      else
        render plain: self.class.large_json_payload
      end
    else
      head 500
    end
  end

  def db
    conn = get_db
    unless conn
      render json: { items: [], count: 0 }
      return
    end

    min_val = (params[:min] || 10).to_f
    max_val = (params[:max] || 50).to_f
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
    conn = get_pg
    unless conn
      render json: { items: [], count: 0 }
      return
    end

    min_val = (params[:min] || 10.0).to_f
    max_val = (params[:max] || 50.0).to_f

    result = conn.exec_params(PG_QUERY, [min_val, max_val])
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
    Thread.current[:rage_pg] = nil
    render json: { items: [], count: 0 }
  end

  def static_file
    if entry = self.class.static_files_cache[params[:filename]]
      headers['content-type'] = entry[:content_type]
      render plain: entry[:data]
    else
      head 404
    end
  end

  def upload
    rack_input = request.send(:rack_request).env["rack.input"]
    rack_input.rewind
    size = 0
    while (chunk = rack_input.read(65536))
      size += chunk.bytesize
    end
    render plain: size.to_s
  end

  def not_found
    head 404
  end

  private

  def get_db
    Fiber[:rage_db] ||= begin
      db = SQLite3::Database.new(self.class.database_path, readonly: true)
      db.execute('PRAGMA mmap_size=268435456')
      db.results_as_hash = true
      db
    rescue
      nil
    end
  end

  def get_pg
    Fiber[:rage_pg] ||= begin
      PG.connect(ENV['DATABASE_URL'])
    rescue
      nil
    end
  end
end
