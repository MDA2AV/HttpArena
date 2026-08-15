module Arena
  module Actions
    class Upload < Arena::Action
      def handle(request, response)
        input = request.env["rack.input"]
        size = 0

        if input
          input.rewind
          while (chunk = input.read(65_536))
            size += chunk.bytesize
          end
        end

        response.format = :txt
        response.body = size.to_s
      end
    end
  end
end
