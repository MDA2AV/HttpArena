require "json"

module Arena
  module Actions
    class Items < Arena::Action
      DATASET = begin
        path = ENV.fetch("DATASET_PATH", "/data/dataset.json")
        File.exist?(path) ? JSON.parse(File.read(path)) : []
      rescue StandardError
        []
      end

      def handle(request, response)
        count = request.params[:count].to_i.clamp(0, DATASET.length)
        m = request.params[:m].to_i
        m = 1 if m.zero?

        items = DATASET.first(count).map do |item|
          item.merge("total" => item["price"] * item["quantity"] * m)
        end

        response.format = :json
        response.body = JSON.generate(items: items, count: items.length)
      end
    end
  end
end
