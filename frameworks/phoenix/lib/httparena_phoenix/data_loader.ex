defmodule HttparenaPhoenix.DataLoader do
  @moduledoc """
  Pre-loads and caches dataset, large dataset, static files, and pre-computed JSON/gzip responses.
  """

  def load do
    dataset_path = System.get_env("DATASET_PATH") || "/data/dataset.json"

    dataset = load_json(dataset_path)
    large_dataset = load_json("/data/dataset-large.json")

    static_files = load_static_files()

    db_available = File.exists?("/data/benchmark.db")

    :persistent_term.put(:dataset, dataset)
    :persistent_term.put(:large_dataset, large_dataset)
    :persistent_term.put(:static_files, static_files)
    :persistent_term.put(:db_available, db_available)
  end

  defp load_json(path) do
    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, items} when is_list(items) -> items
          _ -> []
        end
      _ -> []
    end
  end

  defp load_static_files do
    case File.ls("/data/static") do
      {:ok, entries} ->
        Enum.reduce(entries, %{}, fn name, acc ->
          path = "/data/static/#{name}"
          case File.read(path) do
            {:ok, data} ->
              Map.put(acc, name, %{data: data, content_type: get_mime(name)})
            _ -> acc
          end
        end)
      _ -> %{}
    end
  end

  defp get_mime(filename) do
    cond do
      String.ends_with?(filename, ".css") -> "text/css"
      String.ends_with?(filename, ".js") -> "application/javascript"
      String.ends_with?(filename, ".html") -> "text/html"
      String.ends_with?(filename, ".woff2") -> "font/woff2"
      String.ends_with?(filename, ".svg") -> "image/svg+xml"
      String.ends_with?(filename, ".webp") -> "image/webp"
      String.ends_with?(filename, ".json") -> "application/json"
      true -> "application/octet-stream"
    end
  end
end
