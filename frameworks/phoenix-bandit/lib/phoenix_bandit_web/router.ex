defmodule PhoenixBanditWeb.Router do
  use PhoenixBanditWeb, :router

  scope "/", PhoenixBanditWeb do
    get "/pipeline", BenchmarkController, :pipeline

    get "/baseline11", BenchmarkController, :baseline_get
    post "/baseline11", BenchmarkController, :baseline_post

    get "/baseline2", BenchmarkController, :baseline_get

    get "/json/:count", BenchmarkController, :json_count

    get "/async-db", BenchmarkController, :async_db

    post "/upload", BenchmarkController, :upload

    get "/ws", BenchmarkController, :ws
  end

  scope "/crud", PhoenixBanditWeb do
    get "/items", CrudController, :list
    get "/items/:id", CrudController, :show
    post "/items", CrudController, :create
    put "/items/:id", CrudController, :update
  end
end
