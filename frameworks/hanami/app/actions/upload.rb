module Arena
  module Actions
    class Upload < Arena::Action
      def handle(request, response)
        size = 0
        buf = request.body

        while (chunk = buf.read(65_536))
          size += chunk.bytesize
        end

        response.format = :txt
        response.body = size.to_s
      end
    end
  end
end
