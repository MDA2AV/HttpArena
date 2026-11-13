# frozen_string_literal: true

# Our Rack application to be executed by rackup

require 'rack'
require 'uri'
require 'json'

Symbol.alias_method(:to_s, :name)

class App
  JSON_TYPE = 'application/json'
  PLAINTEXT_TYPE = 'text/plain'
  DELAY_REGEXP = %r[\A/delay/(\d+)\z]
  JSON_REGEXP = %r[\A/json/(\d+)\z]
  DATA_DIR = ENV.fetch('DATA_DIR', '/data')

  def call(env)
    case env['PATH_INFO']
    when '/pipeline'
      render_plain 'ok'
    when '/baseline11'
      params = URI.decode_www_form(env['QUERY_STRING']).to_h
      total = params['a'].to_i + params['b'].to_i
      if env['REQUEST_METHOD'] == 'POST'
        body = env["rack.input"]&.read
        total += body.to_i
      end
      render_plain total.to_s
    when '/baseline2'
      params = URI.decode_www_form(env['QUERY_STRING']).to_h
      total = params['a'].to_i + params['b'].to_i
      render_plain total.to_s
    when JSON_REGEXP
      count = $1.to_i
      params = URI.decode_www_form(env['QUERY_STRING']).to_h
      m = params['m'].to_i
      items = self.class.dataset.slice(0, count).map do |d|
        d.merge(total: (d[:price] * d[:quantity] * m))
      end
      render_json JSON.generate(items: items, count: count)
    when DELAY_REGEXP
      ms = $1.to_i
      sleep(ms / 1000.0) if ms > 0
      render_plain ms.to_s
    else
      [404, {Rack::CONTENT_TYPE => PLAINTEXT_TYPE}, ['Not found!']]
    end
  end

  private

  def self.dataset
    @dataset ||= begin
      dataset_path = File.join DATA_DIR, 'dataset.json'
      if File.exist?(dataset_path)
        JSON.parse(File.read(dataset_path)).map do |item|
          item.transform_keys!(&:to_sym)
          item[:rating].transform_keys!(&:to_sym)
          item
        end
      end
    end
  end

  def render_json(body)
    [200, {Rack::CONTENT_TYPE => JSON_TYPE}, [body]]
  end

  def render_plain(body)
    [200, {Rack::CONTENT_TYPE => PLAINTEXT_TYPE}, [body]]
  end
end
