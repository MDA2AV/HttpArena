require "hanami"

class Hash
  def symbolize_keys!
    transform_keys! { |key| key.to_sym }
  end
end

module Arena
  class App < Hanami::App
    environment(:production) do
      config.logger.level = :error
    end
  end
end
