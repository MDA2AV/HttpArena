defmodule HttpArena.MixProject do
  use Mix.Project

  def project do
    [
      app: :httparena,
      version: "1.0.0",
      elixir: "~> 1.17",
      start_permanent: true,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {HttpArena.Application, []}
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.9"},
      {:jason, "~> 1.4"}
    ]
  end
end
