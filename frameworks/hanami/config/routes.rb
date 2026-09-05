module Arena
  class Routes < Hanami::Routes
    get  '/pipeline', to: ->(env) do
      [200, {
        'content-type' => 'text/plain'
      }, ['ok']]
    end
    get '/delay/:ms', to: ->(env) do
      ms = env['router.params'][:ms].to_i
      # Rack on Puma's thread pool, so the wait holds the thread serving this request.
      sleep(ms / 1000.0) if ms > 0
      [200, { 'content-type' => 'text/plain' }, [ms.to_s]]
    end
    get "/baseline11", to: "baseline11"
    post "/baseline11", to: "baseline11"
    get "/json/:count", to: "items"
    post "/echo", to: "echo"
  end
end
