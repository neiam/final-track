defmodule FinalTrack.Catalog do
  @moduledoc """
  Artists, albums and tracks, shared by everyone.

  Each is found by a normalised name (`normalize/1`), never by the exact
  text a client sent, so case and spacing differences between players
  collapse into one entry. The first spelling seen is the one shown.
  """
  import Ecto.Query, warn: false

  alias FinalTrack.Catalog.{Album, Artist, Track}
  alias FinalTrack.Repo

  @doc """
  The matching key for a name: Unicode-normalised, lowercased, with runs of
  whitespace collapsed and the ends trimmed.
  """
  def normalize(name) when is_binary(name) do
    name
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.join(" ")
  end

  @doc "Finds or creates the artist named `name`."
  def ensure_artist!(name) do
    upsert!(%Artist{name: name, key: normalize(name), tag: hashtag(name)}, [:key])
  end

  @doc """
  A name as a hashtag: lowercased, keeping only letters and digits
  ("Pink Floyd" → "pinkfloyd", "AC/DC" → "acdc"). nil when that leaves
  nothing usable: empty, or only digits, which no server takes as a tag.
  """
  def hashtag(name) when is_binary(name) do
    tag = name |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "")
    if tag =~ ~r/\p{L}/u, do: tag, else: nil
  end

  def hashtag(_), do: nil

  @doc "Finds or creates the album `title` under `artist`."
  def ensure_album!(%Artist{id: artist_id}, title) do
    upsert!(%Album{artist_id: artist_id, title: title, key: normalize(title)}, [:artist_id, :key])
  end

  @doc """
  Finds or creates the track `title` under `artist`. A duration fills in a
  track that had none; it never overwrites one.
  """
  def ensure_track!(%Artist{id: artist_id}, title, duration_sec \\ nil) do
    track =
      upsert!(
        %Track{artist_id: artist_id, title: title, key: normalize(title)},
        [:artist_id, :key]
      )

    if is_nil(track.duration_sec) and is_integer(duration_sec) and duration_sec > 0 do
      track |> Ecto.Changeset.change(duration_sec: duration_sec) |> Repo.update!()
    else
      track
    end
  end

  # A no-op update on conflict, so RETURNING hands back the existing row
  # (ON CONFLICT DO NOTHING returns nothing, and the struct would carry an
  # id that was never stored). Safe under concurrent first scrobbles.
  defp upsert!(struct, target) do
    Repo.insert!(struct,
      on_conflict: {:replace, [:key]},
      conflict_target: target,
      returning: true
    )
  end

  def get_artist!(id), do: Repo.get!(Artist, id)

  def get_album!(id), do: Album |> Repo.get!(id) |> Repo.preload(:artist)

  def get_album(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Album |> Repo.get(id) |> Repo.preload(:artist)
      :error -> nil
    end
  end

  def get_track!(id), do: Track |> Repo.get!(id) |> Repo.preload(:artist)

  @doc "An artist's albums, by title."
  def list_artist_albums(%Artist{id: id}) do
    from(a in Album, where: a.artist_id == ^id, order_by: a.key) |> Repo.all()
  end

  @doc """
  Albums with no cover that have never been looked up: what an automatic
  cover fetch should try. Newest first.
  """
  def albums_needing_cover(limit \\ 50) do
    from(a in Album,
      where: is_nil(a.cover_key) and is_nil(a.cover_checked_at),
      order_by: [desc: a.inserted_at],
      limit: ^limit,
      preload: :artist
    )
    |> Repo.all()
  end

  @doc "Records a cover for `album`. Returns the updated album and the key it replaced."
  def put_cover(%Album{} = album, key, source, attrs \\ %{}) do
    previous = album.cover_key

    album
    |> Ecto.Changeset.change(
      Map.merge(
        %{cover_key: key, cover_source: source, cover_checked_at: DateTime.utc_now(:second)},
        attrs
      )
    )
    |> Repo.update()
    |> case do
      {:ok, album} -> {:ok, Repo.preload(album, :artist), previous}
      error -> error
    end
  end

  @doc "Removes `album`'s cover. Returns the updated album and the key it removed."
  def clear_cover(%Album{} = album) do
    previous = album.cover_key

    album
    |> Ecto.Changeset.change(cover_key: nil, cover_source: nil)
    |> Repo.update()
    |> case do
      {:ok, album} -> {:ok, Repo.preload(album, :artist), previous}
      error -> error
    end
  end

  @doc "Notes that a cover lookup ran (and maybe found the MusicBrainz id) without a cover."
  def mark_cover_checked(%Album{} = album, attrs \\ %{}) do
    album
    |> Ecto.Changeset.change(Map.put(attrs, :cover_checked_at, DateTime.utc_now(:second)))
    |> Repo.update()
  end
end
