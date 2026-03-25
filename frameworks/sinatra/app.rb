require 'sinatra/base'
require 'json'
require 'zlib'
require 'stringio'
require 'sqlite3'

class App < Sinatra::Base
  configure do
    set :server, :puma
    set :logging, false
    set :show_exceptions, false
    disable :static
    disable :protection
    set :host_authorization, { permitted_hosts: [] }

    # Load dataset
    dataset_path = ENV.fetch('DATASET_PATH', '/data/dataset.json')
    if File.exist?(dataset_path)
      set :dataset_items, JSON.parse(File.read(dataset_path))
    else
      set :dataset_items, nil
    end

    # Large dataset for compression
    large_path = '/data/dataset-large.json'
    if File.exist?(large_path)
      raw = JSON.parse(File.read(large_path))
      items = raw.map do |d|
        d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0)
      end
      set :large_json_payload, JSON.generate({ 'items' => items, 'count' => items.length })
    else
      set :large_json_payload, nil
    end

    # SQLite
    set :db_available, File.exist?('/data/benchmark.db')
  end

  DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'

  helpers do
    def get_db
      Thread.current[:sinatra_db] ||= begin
        db = SQLite3::Database.new('/data/benchmark.db', readonly: true)
        db.execute('PRAGMA mmap_size=268435456')
        db.results_as_hash = true
        db
      end
    end
  end

  get '/pipeline' do
    content_type 'text/plain'
    headers 'Server' => 'sinatra'
    'ok'
  end

  def handle_baseline11
    total = 0
    request.GET.each do |_k, v|
      total += v.to_i if v =~ /\A-?\d+\z/
    end
    if request.post?
      request.body.rewind
      body_str = request.body.read.strip
      total += body_str.to_i if body_str =~ /\A-?\d+\z/
    end
    content_type 'text/plain'
    headers 'Server' => 'sinatra'
    total.to_s
  end

  get('/baseline11') { handle_baseline11 }
  post('/baseline11') { handle_baseline11 }

  get '/baseline2' do
    total = 0
    request.GET.each do |_k, v|
      total += v.to_i if v =~ /\A-?\d+\z/
    end
    content_type 'text/plain'
    headers 'Server' => 'sinatra'
    total.to_s
  end

  get '/json' do
    dataset = settings.dataset_items
    halt 500, 'No dataset' unless dataset
    items = dataset.map do |d|
      d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0)
    end
    content_type 'application/json'
    headers 'Server' => 'sinatra'
    JSON.generate({ 'items' => items, 'count' => items.length })
  end

  get '/compression' do
    payload = settings.large_json_payload
    halt 500, 'No dataset' unless payload
    sio = StringIO.new
    gz = Zlib::GzipWriter.new(sio, 1)
    gz.write(payload)
    gz.close
    content_type 'application/json'
    headers 'Content-Encoding' => 'gzip', 'Server' => 'sinatra'
    sio.string
  end

  get '/db' do
    unless settings.db_available
      content_type 'application/json'
      headers 'Server' => 'sinatra'
      return '{"items":[],"count":0}'
    end
    min_val = (params['min'] || 10).to_f
    max_val = (params['max'] || 50).to_f
    db = get_db
    rows = db.execute(DB_QUERY, [min_val, max_val])
    items = rows.map do |r|
      {
        'id' => r['id'], 'name' => r['name'], 'category' => r['category'],
        'price' => r['price'], 'quantity' => r['quantity'], 'active' => r['active'] == 1,
        'tags' => JSON.parse(r['tags']),
        'rating' => { 'score' => r['rating_score'], 'count' => r['rating_count'] }
      }
    end
    content_type 'application/json'
    headers 'Server' => 'sinatra'
    JSON.generate({ 'items' => items, 'count' => items.length })
  end

  # POST /upload is handled by UploadHandler middleware in config.ru
  # to bypass Rack's body param parsing (binary data with no Content-Type
  # causes "invalid %-encoding" errors in Rack's URL decoder)
end
