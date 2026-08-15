module Arena
  module Actions
    class Pipeline < Arena::Action
      def handle(request, response)
        response.format = :txt
        response.body = "ok"
      end
    end
  end
end
