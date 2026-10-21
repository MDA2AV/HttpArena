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
      config.actions.default_headers = {}
      config.actions.content_security_policy = false
    end
  end
end
