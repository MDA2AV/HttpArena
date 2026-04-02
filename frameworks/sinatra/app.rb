# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

require 'zlib'
require 'pg'

class App < Sinatra::Base
  SERVER_NAME = 'sinatra'.freeze

  configure do
    set :server, :puma
    set :logging, false
    set :show_exceptions, false

    # Disable unused protections
    disable :static
    disable :protection
    set :host_authorization, { permitted_hosts: [] }

    # Set root once instead executing the proc on every request
    set :root, File.expand_path(__dir__)

    # Load dataset
    DATA_DIR = ENV.fetch('DATA_DIR', '/data')
    dataset_path = File.join DATA_DIR, 'dataset.json'
    if File.exist?(dataset_path)
      set :dataset_items, JSON.parse(File.read(dataset_path))
    else
      set :dataset_items, nil
    end

    # Large dataset for compression
    dataset_large_path = File.join DATA_DIR, 'dataset-large.json'
    if File.exist?(dataset_large_path)
      raw = JSON.parse(File.read(dataset_large_path))
      items = raw.map do |d|
        d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0)
      end
      set :large_json_payload, JSON.generate({ 'items' => items, 'count' => items.length })
    else
      set :large_json_payload, nil
    end

    # Static files
    mime_types = {
      '.css'   => 'text/css',
      '.js'    => 'application/javascript',
      '.html'  => 'text/html',
      '.woff2' => 'font/woff2',
      '.svg'   => 'image/svg+xml',
      '.webp'  => 'image/webp',
      '.json'  => 'application/json'
    }.freeze

    static_dir = File.join DATA_DIR, 'static'
    if Dir.exist?(static_dir)
      cache = {}
      Dir.foreach(static_dir) do |name|
        next if name == '.' || name == '..'
        path = File.join(static_dir, name)
        next unless File.file?(path)
        ext = File.extname(name)
        ct = mime_types.fetch(ext, 'application/octet-stream')
        cache[name] = { data: File.binread(path), content_type: ct }
      end
      set :static_files_cache, cache
    else
      set :static_files_cache, {}
    end

    # SQLite
    set :database_path, File.join(DATA_DIR, 'benchmark.db')
  end

  DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'.freeze
  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50'.freeze

  helpers do
    def get_db
      Thread.current[:sinatra_db] ||= begin
        db = SQLite3::Database.new(settings.database_path, readonly: true)
        db.execute('PRAGMA mmap_size=268435456')
        db.results_as_hash = true
        db
      rescue
        nil
      end
    end

    def pg_conn
      Thread.current[:sinatra_pg] ||= begin
        url = ENV['DATABASE_URL']
        return nil unless url
        db = PG.connect(url)
        db.prepare('select', PG_QUERY)
        db
      rescue PG::Error
        nil
      end
    end
  end

  get '/pipeline' do
    content_type 'text/plain'
    headers 'Server' => SERVER_NAME
    'ok'
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
    content_type 'text/plain'
    headers 'Server' => SERVER_NAME
    total.to_s
  end

  get('/baseline11') { handle_baseline11 }
  post('/baseline11') { handle_baseline11 }

  get '/baseline2' do
    total = 0
    request.GET.each do |_k, v|
      total += v.to_i
    end
    content_type 'text/plain'
    headers 'Server' => SERVER_NAME
    total.to_s
  end

  get '/json' do
    dataset = settings.dataset_items
    halt 500, 'No dataset' unless dataset
    items = dataset.map do |d|
      d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0)
    end
    content_type 'application/json'
    headers 'Server' => SERVER_NAME
    JSON.generate({ 'items' => items, 'count' => items.length })
  end

  get '/compression' do
    dataset = settings.large_json_payload
    halt 500, 'No dataset' unless dataset
    if request.get_header('HTTP_ACCEPT_ENCODING')&.include?('gzip')
      sio = StringIO.new
      gz = Zlib::GzipWriter.new(sio, 1)
      gz.write(dataset)
      gz.close
      content_type 'application/json'
      headers 'Content-Encoding' => 'gzip', 'Server' => SERVER_NAME
      sio.string
    else
      content_type 'application/json'
      headers 'Server' => SERVER_NAME
      dataset
    end
  end

  get '/db' do
    min_val = (params['min'] || 10).to_i
    max_val = (params['max'] || 50).to_i

    rows = get_db&.execute(DB_QUERY, [min_val, max_val]) || []

    items = rows.map do |r|
      {
        'id' => r['id'], 'name' => r['name'], 'category' => r['category'],
        'price' => r['price'], 'quantity' => r['quantity'], 'active' => r['active'] == 1,
        'tags' => JSON.parse(r['tags']),
        'rating' => { 'score' => r['rating_score'], 'count' => r['rating_count'] }
      }
    end
    content_type 'application/json'
    headers 'Server' => SERVER_NAME
    JSON.generate({ 'items' => items, 'count' => items.length })
  end

  get '/async-db' do
    min_val = (params['min'] || 10).to_i
    max_val = (params['max'] || 50).to_i

    rows = pg_conn&.exec_prepared('select', [min_val, max_val]) || []

    items = rows.map do |r|
      {
        'id' => r['id'].to_i, 'name' => r['name'], 'category' => r['category'],
        'price' => r['price'].to_f, 'quantity' => r['quantity'].to_i,
        'active' => r['active'] == 't',
        'tags' => JSON.parse(r['tags']),
        'rating' => { 'score' => r['rating_score'].to_f, 'count' => r['rating_count'].to_i }
      }
    end
    content_type 'application/json'
    headers 'Server' => SERVER_NAME
    JSON.generate({ 'items' => items, 'count' => items.length })
  end

  get '/static/:filename' do
    filename = params['filename']
    entry = settings.static_files_cache[filename]
    if entry
      content_type entry[:content_type]
      headers 'Server' => SERVER_NAME
      entry[:data]
    else
      headers 'Server' => SERVER_NAME
      halt 404, 'Not Found'
    end
  end

  # POST /upload is handled by UploadHandler middleware in config.ru
  # to bypass Rack's body param parsing (binary data with no Content-Type
  # causes "invalid %-encoding" errors in Rack's URL decoder)
end
