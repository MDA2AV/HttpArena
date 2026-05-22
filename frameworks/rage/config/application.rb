# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

require 'rage/all'

Rage.configure do
  # use this to add settings that are constant across all environments
  config.public_file_server.enabled = true
  config.middleware.use Rack::Deflater # enable gzip
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
