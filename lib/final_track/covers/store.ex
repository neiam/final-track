defmodule FinalTrack.Covers.Store do
  @moduledoc """
  Cover images on local disk, under `config :final_track, FinalTrack.Covers,
  root: ...` (default `priv/uploads`). Keys are relative paths like
  `covers/<album id>/<random>.jpg`. Served by `FinalTrackWeb.CoverController`,
  never as static files.
  """

  def root do
    Application.get_env(:final_track, FinalTrack.Covers, [])
    |> Keyword.get(:root, Path.join(:code.priv_dir(:final_track), "uploads"))
    |> Path.expand()
  end

  @doc "Writes `bytes` under `key`."
  def put(key, bytes) when is_binary(bytes) do
    with {:ok, dest} <- path(key),
         :ok <- File.mkdir_p(Path.dirname(dest)) do
      File.write(dest, bytes)
    end
  end

  @doc "The file behind `key`, if it exists."
  def fetch(key) when is_binary(key) do
    with {:ok, path} <- path(key), true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end

  def fetch(_), do: {:error, :not_found}

  def delete(nil), do: :ok

  def delete(key) do
    with {:ok, path} <- path(key), do: File.rm(path)
    :ok
  end

  # Keys come from our own code, but one must never climb out of root.
  defp path(key) do
    root = root()
    path = Path.expand(key, root)
    if String.starts_with?(path, root <> "/"), do: {:ok, path}, else: {:error, :bad_key}
  end
end
