# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default) # Load core modules

require 'uri'

class BaseHandler
  CONTENT_TYPE = 'Content-Type'
  PLAINTEXT_TYPE = 'text/plain'

  private

  def render_plain(body)
    [200, {CONTENT_TYPE => PLAINTEXT_TYPE}, [body]]
  end
end

class PipelineHandler < BaseHandler
  def call(env)
    render_plain 'ok'
  end
end

class Baseline11Handler < BaseHandler
  def call(env)
    params = URI.decode_www_form(env['QUERY_STRING']).to_h
    total = params['a'].to_i + params['b'].to_i
    if env['REQUEST_METHOD'] == 'POST'
      body = env["rack.input"]&.read
      total += body.to_i
    end
    render_plain total.to_s
  end
end

class Baseline2Handler < BaseHandler
  def call(env)
    params = URI.decode_www_form(env['QUERY_STRING']).to_h
    total = params['a'].to_i + params['b'].to_i
    render_plain total.to_s
  end
end

# Disable logging
Agoo::Log.configure(
  console: false,
  dir: '',
  states: {
    ERROR: false,
    WARN: false,
    INFO: false,
    DEBUG: false,
    connect: false,
    request: false,
    response: false,
    eval: false,
    push: false
  }
)

Agoo::Server.init(8080, '.', thread_count: 0)

Agoo::Server.handle :GET,  '/pipeline',   PipelineHandler.new
Agoo::Server.handle :GET,  '/baseline11', Baseline11Handler.new
Agoo::Server.handle :POST, '/baseline11', Baseline11Handler.new
Agoo::Server.handle :GET,  '/baseline2',  Baseline2Handler.new

Agoo::Server.start
