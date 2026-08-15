module Arena
  class Routes < Hanami::Routes
    get "/pipeline", to: "pipeline"
    get "/baseline11", to: "baseline11"
    post "/baseline11", to: "baseline11"
    get "/json/:count", to: "items"
    post "/upload", to: "upload"
  end
end
