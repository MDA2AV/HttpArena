module Arena
  class Routes < Hanami::Routes
    get  '/pipeline', to: ->(env) do
      [200, {
        'content-type' => 'text/plain'
      }, ['ok']]
    end
    get "/baseline11", to: "baseline11"
    post "/baseline11", to: "baseline11"
    get "/json/:count", to: "items"
    post "/echo", to: "echo"
  end
end
