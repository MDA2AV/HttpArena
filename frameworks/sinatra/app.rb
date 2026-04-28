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
  SERVER_NAME = 'sinatra'.freeze

  configure do
    set :server, :puma
    set :logging, false
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
    render_json JSON.generate(items: items, count: items.length)
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
end
