# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

require 'rage/all'

Rage.configure do
  # use this to add settings that are constant across all environments
end

require "rage/setup"

# Silence warnings
$VERBOSE = nil

# Monkeypatch the parser to handle a request body that isn't multipart
Rage::ParamsParser.class_eval do
  def self.prepare(env, url_params)
    has_body, query_string, content_type = env["IODINE_HAS_BODY"], env["QUERY_STRING"], env["CONTENT_TYPE"].to_s

    query_params = Iodine::Rack::Utils.parse_nested_query(query_string) if query_string != ""
    unless has_body
      if query_params
        return query_params.merge!(url_params)
      else
        return url_params
      end
    end

    request_params = if content_type.start_with?("application/json")
      json_parse(env["rack.input"].read)
    elsif content_type.start_with?("application/x-www-form-urlencoded")
      Iodine::Rack::Utils.parse_urlencoded_nested_query(env["rack.input"].read)
    # only parse multipart if content-type is mulitpart
    elsif content_type.start_with?("multipart/form-data")
      Iodine::Rack::Utils.parse_multipart(env["rack.input"], content_type)
    end

    if request_params && !query_params
      request_params.merge!(url_params)
    elsif request_params && query_params
      request_params.merge!(query_params, url_params)
    elsif query_params
      query_params.merge!(url_params)
    else
      url_params
    end

  rescue
    raise Rage::Errors::BadRequest
  end
end

# Monkey patch render to latest unreleased version.
# This allow overriding the content-type for the static test.
# https://github.com/rage-rb/rage/blob/1ce455a34f8548e7533184f7eae7e47ae2c64c72/lib/rage/controller/api.rb#L530-L567
RageController::API.class_eval do
  DEFAULT_CONTENT_TYPE = "application/json; charset=utf-8"

  def render(json: nil, plain: nil, sse: nil, status: nil)
    raise "Render was called multiple times in this action." if @__rendered
    @__rendered = true

    if json || plain
      @__body << if json
        json.is_a?(String) ? json : json.to_json
      else
        ct = @__headers["content-type"]
        @__headers["content-type"] = "text/plain; charset=utf-8" if ct.nil? || ct == DEFAULT_CONTENT_TYPE
        plain.to_s
      end

      @__status = 200
    end

    if status
      @__status = if status.is_a?(Symbol)
        ::Rack::Utils::SYMBOL_TO_STATUS_CODE[status]
      else
        status
      end
    end

    if sse
      raise ArgumentError, "Cannot render both a standard body and an SSE stream." unless @__body.empty?

      if status
        return if @__status == 204
        raise ArgumentError, "SSE responses only support 200 and 204 statuses." if @__status != 200
      end

      @__env["rack.upgrade?"] = :sse
      @__env["rack.upgrade"] = Rage::SSE::Application.new(sse)
      @__status = 200
      @__headers["content-type"] = "text/event-stream; charset=utf-8"
    end
  end
end
