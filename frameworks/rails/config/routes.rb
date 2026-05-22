Rails.application.routes.draw do
  get  '/pipeline', to: ->(env) do
    [200, {
      'content-type' => 'text/plain'
    }, ['ok']]
  end
  get  '/baseline11',  to: 'benchmark#baseline11'
  post '/baseline11',  to: 'benchmark#baseline11'
  get  '/baseline2',   to: 'benchmark#baseline2'
  get  '/json/:count', to: 'benchmark#json_endpoint'
  get  '/async-db',    to: 'benchmark#async_db'
  post '/upload',      to: 'benchmark#upload'

  # Catch-all for unknown paths → 404
  match '*path', to: 'benchmark#not_found', via: :all
end
