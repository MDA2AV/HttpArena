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
