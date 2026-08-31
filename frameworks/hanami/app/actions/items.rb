require "json"

module Arena
  module Actions
    class Items < Arena::Action
      # Load dataset
      DATA_DIR = ENV.fetch('DATA_DIR', '/data')
      dataset_path = File.join DATA_DIR, 'dataset.json'
      if File.exist?(dataset_path)
        items = JSON.parse(File.read(dataset_path)).map do |item|
          item.symbolize_keys!
          item[:rating].symbolize_keys!
          item
        end
        DATASET = items
      end

      def handle(request, response)
        count = request.params[:count].to_i.clamp(0, DATASET.length)
        m = (request.params[:m] || 1).to_i

        items = DATASET.slice(0, count).map do |item|
          item.merge(total: item[:price] * item[:quantity] * m)
        end

        response.format = :json
        response.body = JSON.generate(items: items, count: count)
      end
    end
  end
end
