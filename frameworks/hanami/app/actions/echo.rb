module Arena
  module Actions
    class Echo < Arena::Action
      def handle(request, response)
        # Read to end regardless of framing, so a chunked request works
        # without a Content-Length to size it from.
        chunks = []
        buf = request.body

        while (chunk = buf.read(65_536))
          chunks << chunk
        end

        response.headers["Content-Type"] = "application/octet-stream"
        response.body = chunks.join
      end
    end
  end
end
