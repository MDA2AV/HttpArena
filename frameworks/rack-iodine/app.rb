# frozen_string_literal: true

# Our Rack application to be executed by rackup

require 'rack'

class App
  CONTENT_TYPE = 'Content-Type'
  PLAINTEXT_TYPE = 'text/plain'

  def call(env)
    case env['PATH_INFO']
    when '/pipeline'
      render_plain 'ok'
    when '/baseline11'
      params = Rack::Utils.parse_query(env['QUERY_STRING'])
      total = params['a'].to_i + params['b'].to_i
      if env['REQUEST_METHOD'] == 'POST'
        body = env["rack.input"]&.read
        total += body.to_i
      end
      render_plain total.to_s
    when '/baseline2'
      params = Rack::Utils.parse_query(env['QUERY_STRING'])
      total = params['a'].to_i + params['b'].to_i
      render_plain total.to_s
    else
      [404, {CONTENT_TYPE => PLAINTEXT_TYPE}, ['Not found!']]
    end
  end

  private

  def render_plain(body)
    [200, {CONTENT_TYPE => PLAINTEXT_TYPE}, [body]]
  end
end

