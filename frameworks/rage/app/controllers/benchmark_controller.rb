# frozen_string_literal: true

require 'zlib'
require 'concurrent/utility/processor_counter'

class Hash
  def symbolize_keys!
    transform_keys! { |key| key.to_sym }
  end
end

class BenchmarkController < RageController::API
  SERVER_NAME = 'rage'.freeze
  DATA_DIR = ENV.fetch('DATA_DIR', '/data')

  dataset_path = File.join DATA_DIR, 'dataset.json'
  if File.exist?(dataset_path)
    @dataset_items = JSON.parse(File.read(dataset_path)).map do |item|
      item.symbolize_keys!
      item[:rating].symbolize_keys!
      item
    end.freeze
  end
  def self.dataset_items = @dataset_items

  FileUtils.cp_r(File.join(DATA_DIR, 'static'), File.join(Rage.root, 'public', 'static'))

  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3'

  before_action do
    headers["server"] = SERVER_NAME
  end

  def baseline_one
    total = params[:a].to_i + params[:b].to_i
    if request.post?
      rack_input = request.send(:rack_request).env["rack.input"]
      rack_input.rewind
      body_str = rack_input.read.strip
      total += body_str.to_i
    end
    render plain: total.to_s
  end

  def baseline_two
    total = params[:a].to_i + params[:b].to_i
    render plain: total.to_s
  end

  def json_endpoint
    m = (params[:m] || 1).to_i
    count = params[:count].to_i

    if self.class.dataset_items
      items = self.class.dataset_items.slice(0, count).map do |d|
        d.merge(total: d[:price] * d[:quantity] * m)
      end
    else
      items = []
    end

    result = { items: items, count: items.length }

    if accept_encodings = request.headers['Accept-Encoding']
      types = accept_encodings.split(',').map(&:strip)
      if types.include? 'gzip'
        sio = StringIO.new
        gz = Zlib::GzipWriter.new(sio, 1)
        gz.write JSON.generate(result)
        gz.close
        headers['Content-Encoding'] = 'gzip'
        headers['Content-Type'] = 'application/json'
        render plain: sio.string
      else
        render json: result
      end
    else
      render json: result
    end
  end

  def async_db
    min_val = (params[:min] || 10).to_i
    max_val = (params[:max] || 50).to_i
    limit = (params[:limit] || 50).to_i.clamp(1, 50)

    rows = self.class.get_async_db&.with do |connection|
      connection.exec_prepared('select', [min_val, max_val, limit])
    end || []

    items = rows.map do |r|
      {
        id: r['id'],
        name: r['name'],
        category: r['category'],
        price: r['price'],
        quantity: r['quantity'],
        active: r['active'] == 't',
        tags: JSON.parse(r['tags']),
        rating: { score: r['rating_score'], count: r['rating_count'] }
      }
    end
    render json: { items: items, count: items.length }
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

  def self.get_async_db
    @async_db ||= begin
      return unless ENV['DATABASE_URL']
      processors = Integer(::Concurrent.available_processor_count)
      pool_size = (2 * Math.log(256 / processors)).floor
      ConnectionPool.new(size: pool_size, timeout: 5) do
        db = PG.connect(ENV['DATABASE_URL'])
        db.prepare('select', PG_QUERY)
        db
      end
    end
  end
end
