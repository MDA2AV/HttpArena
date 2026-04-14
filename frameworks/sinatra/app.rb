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
      set :dataset_items, JSON.parse(File.read(dataset_path)).freeze
    else
      set :dataset_items, nil
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
      set :static_files_cache, cache.freeze
    else
      set :static_files_cache, {}
    end

  end

  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3'.freeze

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
    total = 0
    request.GET.each do |_k, v|
      total += v.to_i
    end
    total += request.body.read.to_i
    render_plain total.to_s
  end

  get '/baseline2' do
    total = 0
    request.GET.each do |_k, v|
      total += v.to_i
    end
    render_plain total.to_s
  end

  get '/json/:count' do
    dataset = settings.dataset_items
    halt 500, 'No dataset' unless dataset
    count = params['count'].to_i
    m = (request.params['m'] || 1).to_i

    items = dataset.slice(0, count).map do |d|
      d.merge('total' => (d['price'] * d['quantity'] * m))
    end

    result = JSON.generate('items' => items, 'count' => items.length)

    if accept_encodings = request.get_header('HTTP_ACCEPT_ENCODING')
      if accept_encodings.include?('gzip')
        sio = StringIO.new
        gz = Zlib::GzipWriter.new(sio, 1)
        gz.write(result)
        gz.close
        headers 'Content-Encoding' => 'gzip'
        result = sio.string
      end
    end
    render_json result
  end

  get '/async-db' do
    min_val = (params['min'] || 10).to_i
    max_val = (params['max'] || 50).to_i
    limit = (params['limit'] || 50).to_i.clamp(1, 50)

    rows = self.class.get_async_db&.with do |connection|
      connection.exec_prepared('select', [min_val, max_val, limit])
    end || []

    items = rows.map do |r|
      {
        'id' => r['id'],
        'name' => r['name'],
        'category' => r['category'],
        'price' => r['price'],
        'quantity' => r['quantity'],
        'active' => r['active'] == 1,
        'tags' => JSON.parse(r['tags']),
        'rating' => { 'score' => r['rating_score'], 'count' => r['rating_count'] }
      }
    end
    render_json JSON.generate({ 'items' => items, 'count' => items.length })
  end

  get '/static/:filename' do
    filename = params['filename']
    entry = settings.static_files_cache[filename]
    if entry
      headers 'server' => SERVER_NAME, 'content-type' => entry[:content_type]
      entry[:data]
    else
      headers 'server' => SERVER_NAME
      halt 404, 'Not Found'
    end
  end

  private

  def render_json(json)
    headers 'server' => SERVER_NAME, 'content-type' => 'application/json'
    json
  end

  def render_plain(text)
    headers 'server' => SERVER_NAME, 'content-type' => 'text/plain'
    text
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

  # POST /upload is handled by UploadHandler middleware in config.ru
  # to bypass Rack's body param parsing (binary data with no Content-Type
  # causes "invalid %-encoding" errors in Rack's URL decoder)
end
