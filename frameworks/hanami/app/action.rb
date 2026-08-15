require "hanami/action"
require "rack"

module Arena
  class Action < Hanami::Action
    private

    # The benchmark posts bodies with no Content-Type, which Rack parses as form
    # data, so the query is read from QUERY_STRING and the body from rack.input.
    def query_sum(request)
      ::Rack::Utils.parse_query(request.env["QUERY_STRING"]).values.sum do |value|
        Array(value).first.to_i
      end
    end

    def request_body(request)
      input = request.env["rack.input"]
      return "" unless input

      input.rewind
      input.read.to_s
    end
  end
end
