defmodule FinalTrackWeb.CoverController do
  @moduledoc """
  Serves album covers, to anyone (the landing grid is public). A cover's URL carries its file
  key's version (`?v=`), and each new cover gets a new key, so browsers may
  cache a cover for a long time.
  """
  use FinalTrackWeb, :controller

  alias FinalTrack.Catalog
  alias FinalTrack.Covers.{Image, Store}

  def show(conn, %{"id" => id}) do
    with %{cover_key: key} when is_binary(key) <- Catalog.get_album(id),
         {:ok, path} <- Store.fetch(key) do
      conn
      |> put_resp_content_type(Image.content_type(key), nil)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, :not_found, "Not Found")
    end
  end
end
