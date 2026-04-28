# frozen_string_literal: true

require 'zlib'
require 'pg'

class BenchmarkController < ActionController::API
  mattr_accessor :dataset

  DATA_DIR = ENV.fetch('DATA_DIR', '/data')
  dataset_path = File.join(DATA_DIR, 'dataset.json')
  static_dir = File.join(DATA_DIR, 'static')

  if File.exist?(dataset_path)
    self.dataset = JSON.parse(File.read(dataset_path)).map(&:deep_symbolize_keys).freeze
  end

  FileUtils.cp_r(File.join(DATA_DIR, 'static'), Rails.root.join('public', 'static'))

  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3'.freeze

  def baseline11
    total = params[:a].to_i + params[:b].to_i
    if request.post?
      total += request.body.read.to_i
    end
    render plain: total.to_s
  end

  def baseline2
    total = params[:a].to_i + params[:b].to_i
    render plain: total.to_s
  end

  def json_endpoint
    return head(500) unless dataset

    m = (params[:m] || 1).to_i
    count = params[:count].to_i
    items = dataset.slice(0, count).map do |d|
      d.merge(total: d[:price] * d[:quantity] * m)
    end

    result = JSON.generate(items: items, count: items.length)

    if accept_encodings = request.headers['Accept-Encoding']
      types = accept_encodings.split(',').map(&:strip)
      if types.include? 'gzip'
        sio = StringIO.new
        gz = Zlib::GzipWriter.new(sio, 1)
        gz.write(result)
        gz.close
        response.headers['content-type'] = 'application/json'
        response.headers['content-encoding'] = 'gzip'
        send_data sio.string, disposition: :inline
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

  def self.get_async_db
    @async_db ||= begin
      return unless ENV['DATABASE_URL'].present?
      max_connections = ENV.fetch('RAILS_MAX_THREADS', 4).to_i
      ConnectionPool.new(size: max_connections, timeout: 5) do
        db = PG.connect(ENV['DATABASE_URL'])
        db.prepare('select', PG_QUERY)
        db
      end
    end
  end
end
