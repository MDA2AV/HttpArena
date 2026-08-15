module Arena
  module Actions
    class Baseline11 < Arena::Action
      def handle(request, response)
        total = query_sum(request)
        total += request_body(request).strip.to_i if request.post?

        response.format = :txt
        response.body = total.to_s
      end
    end
  end
end
