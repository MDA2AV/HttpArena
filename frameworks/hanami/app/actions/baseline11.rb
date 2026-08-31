module Arena
  module Actions
    class Baseline11 < Arena::Action
      def handle(request, response)
        total = request.params[:a].to_i + request.params[:b].to_i
        if request.post?
          total += request.body.read.to_i
        end

        response.format = :txt
        response.body = total.to_s
      end
    end
  end
end
