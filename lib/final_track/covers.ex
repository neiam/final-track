defmodule FinalTrack.Covers do
  @moduledoc """
  Album covers: uploaded by a person, or fetched from MusicBrainz and the
  Cover Art Archive (`FinalTrack.Covers.Fetcher`).

  Fetches run through `FinalTrack.Covers.Queue`, one at a time. With
  `config :final_track, FinalTrack.Covers, auto_fetch: true` an album that
  has no cover and was never looked up is queued as soon as it's played.

  Changes are broadcast on the `"covers"` topic:
  `{:cover_updated, album_id}` and `{:cover_fetch_failed, album_id, reason}`.
  """
  require Logger

  alias FinalTrack.Catalog
  alias FinalTrack.Catalog.Album
  alias FinalTrack.Covers.{Fetcher, Image, Queue, Store}

  @topic "covers"

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(FinalTrack.PubSub, @topic)

  defp config, do: Application.get_env(:final_track, __MODULE__, [])

  @doc "Queues a lookup for `album` if automatic fetching is on and it has never been tried."
  def maybe_fetch(%Album{cover_key: nil, cover_checked_at: nil} = album) do
    if Keyword.get(config(), :auto_fetch, false), do: Queue.enqueue(album.id)
    :ok
  end

  def maybe_fetch(_album), do: :ok

  @doc "Queues a lookup for `album` now, whatever it has (a person asked for it)."
  def request_fetch(%Album{id: id}), do: Queue.enqueue(id)

  @doc """
  Looks up and stores the cover for the album with `id`, right away. The
  queue calls this; anything else should go through `request_fetch/1`.
  """
  def fetch_cover_now(id) do
    with %Album{} = album <- Catalog.get_album(id) do
      result =
        case Fetcher.fetch(album) do
          {:ok, %{bytes: bytes, mbid: mbid}} ->
            store(album, bytes, "coverartarchive", %{mbid: mbid})

          {:error, {:no_cover, mbid}} ->
            Catalog.mark_cover_checked(album, %{mbid: mbid})
            {:error, :no_cover}

          {:error, :no_match} ->
            Catalog.mark_cover_checked(album)
            {:error, :no_match}

          {:error, reason} ->
            # Transient (network, rate limit): not marked, so it's tried again.
            Logger.warning("cover lookup for album #{album.id} failed: #{inspect(reason)}")
            {:error, :unavailable}
        end

      case result do
        {:ok, album} -> broadcast({:cover_updated, album.id})
        {:error, reason} -> broadcast({:cover_fetch_failed, album.id, reason})
      end

      result
    end
  end

  @doc "Stores an uploaded file as `album`'s cover."
  def put_upload(%Album{} = album, path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, album} <- store(album, bytes, "upload") do
      broadcast({:cover_updated, album.id})
      {:ok, album}
    end
  end

  @doc "Removes `album`'s cover (and doesn't fetch it back automatically)."
  def remove(%Album{} = album) do
    with {:ok, album, previous} <- Catalog.clear_cover(album) do
      Store.delete(previous)
      broadcast({:cover_updated, album.id})
      {:ok, album}
    end
  end

  # A new random name per cover, so a cached copy of the old one is never
  # served under the new one's URL.
  defp store(album, bytes, source, attrs \\ %{}) do
    with {:ok, ext} <- Image.sniff(bytes),
         key = "covers/#{album.id}/#{Base.url_encode64(:crypto.strong_rand_bytes(9))}.#{ext}",
         :ok <- Store.put(key, bytes),
         {:ok, album, previous} <- Catalog.put_cover(album, key, source, attrs) do
      Store.delete(previous)
      {:ok, album}
    end
  end

  @doc "A human sentence for a fetch failure."
  def describe_failure(:no_match), do: "MusicBrainz doesn't know this album."
  def describe_failure(:no_cover), do: "MusicBrainz knows this album, but has no cover for it."
  def describe_failure(:not_an_image), do: "That file isn't a JPEG, PNG or WebP image."
  def describe_failure(:too_large), do: "That image is too large."
  def describe_failure(_), do: "Couldn't reach MusicBrainz. Try again in a moment."

  defp broadcast(message), do: Phoenix.PubSub.broadcast(FinalTrack.PubSub, @topic, message)
end
