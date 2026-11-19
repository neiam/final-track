defmodule FinalTrack.Catalog.Repair do
  @moduledoc """
  Moves plays recorded under a tangled artist name — a player's subtitle
  such as "Cage The Elephant • Tell Me I'm Pretty • YouTube Music", from
  before `FinalTrack.Scrobbles.validate_play/1` untangled them — onto the
  artist, album and track they should have had, then deletes the tangled
  entries. From a release (`bin/repair-artists`, a dry run unless
  `--apply`).

  Per tangled artist, in one transaction:

    * each of its tracks maps to the same title under the real artist; its
      plays move there (a play the real track already has at the same
      moment, for the same user, is a duplicate and is deleted);
    * each of its albums maps to the same title under the real artist,
      bringing its cover if the real album has none; plays that had no
      album get the one named in the subtitle;
    * private marks follow (or are dropped as duplicates); now-playing rows
      on it are cleared;
    * the tangled artist is deleted, with its now-empty albums and tracks.

  Fediverse posts already delivered keep their old text.
  """
  import Ecto.Query

  alias FinalTrack.Catalog
  alias FinalTrack.Catalog.{Album, Artist, Track}
  alias FinalTrack.Repo
  alias FinalTrack.Scrobbles
  alias FinalTrack.Scrobbles.{NowPlaying, PrivateMark, Scrobble}

  @doc """
  The tangled artists and what each would become: `[{artist, name, album}]`.
  """
  def tangled do
    from(a in Artist, where: like(a.name, "%•%") or like(a.name, "%·%"), order_by: a.name)
    |> Repo.all()
    |> Enum.flat_map(fn artist ->
      case Scrobbles.untangle_artist(artist.name, nil) do
        {name, _} when name == artist.name -> []
        {name, album} -> [{artist, name, album}]
      end
    end)
  end

  @doc """
  Reports, and with `apply: true` repairs, every tangled artist. Returns a
  list of lines describing what happened (or would).
  """
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)

    case tangled() do
      [] ->
        ["nothing to repair"]

      found ->
        Enum.flat_map(found, fn {artist, name, album} ->
          plays = Repo.aggregate(from(s in Scrobble, where: s.artist_id == ^artist.id), :count)

          head =
            "#{inspect(artist.name)} → #{inspect(name)}#{album && ", album #{inspect(album)}"} (#{plays} plays)"

          if apply? do
            {:ok, stats} = Repo.transaction(fn -> repair(artist, name, album) end)
            [head <> ": moved #{stats.moved}, dropped #{stats.dropped} duplicates"]
          else
            [head]
          end
        end)
    end
  end

  defp repair(%Artist{} = bad, name, subtitle_album) do
    target = Catalog.ensure_artist!(name)

    albums =
      from(a in Album, where: a.artist_id == ^bad.id)
      |> Repo.all()
      |> Map.new(fn album -> {album.id, move_album(album, target)} end)

    subtitle_album = subtitle_album && Catalog.ensure_album!(target, subtitle_album)

    tracks =
      from(t in Track, where: t.artist_id == ^bad.id)
      |> Repo.all()
      |> Map.new(fn t -> {t.id, Catalog.ensure_track!(target, t.title, t.duration_sec)} end)

    # Plays of the tangled tracks, and plays of other artists' tracks filed
    # under one of the tangled albums (as album artist).
    plays =
      from(s in Scrobble,
        where: s.artist_id == ^bad.id or s.album_id in ^Map.keys(albums)
      )
      |> Repo.all()

    stats =
      Enum.reduce(plays, %{moved: 0, dropped: 0}, fn play, stats ->
        track = Map.get(tracks, play.track_id)

        album_id =
          cond do
            play.album_id && Map.has_key?(albums, play.album_id) -> albums[play.album_id].id
            is_nil(play.album_id) && track && subtitle_album -> subtitle_album.id
            true -> play.album_id
          end

        changes =
          if track,
            do: [track_id: track.id, artist_id: target.id, album_id: album_id],
            else: [album_id: album_id]

        duplicate? =
          track &&
            Repo.exists?(
              from(s in Scrobble,
                where:
                  s.user_id == ^play.user_id and s.track_id == ^track.id and
                    s.played_at == ^play.played_at and s.id != ^play.id
              )
            )

        if duplicate? do
          Repo.delete!(play)
          %{stats | dropped: stats.dropped + 1}
        else
          play |> Ecto.Changeset.change(changes) |> Repo.update!()
          %{stats | moved: stats.moved + 1}
        end
      end)

    move_marks(:artist_id, %{bad.id => target})
    move_marks(:album_id, albums)
    move_marks(:track_id, tracks)

    from(n in NowPlaying,
      where: n.track_id in ^Map.keys(tracks) or n.album_id in ^Map.keys(albums)
    )
    |> Repo.delete_all()

    Repo.delete!(bad)
    stats
  end

  # The same title under the real artist, with the tangled one's cover and
  # MusicBrainz id when it has none of its own.
  defp move_album(%Album{} = album, %Artist{} = target) do
    real = Catalog.ensure_album!(target, album.title)

    if is_nil(real.cover_key) and album.cover_key do
      real
      |> Ecto.Changeset.change(
        cover_key: album.cover_key,
        cover_source: album.cover_source,
        mbid: real.mbid || album.mbid,
        cover_checked_at: album.cover_checked_at
      )
      |> Repo.update!()
    else
      real
    end
  end

  defp move_marks(field, mapping) do
    for {old_id, new} <- mapping,
        mark <- Repo.all(from(m in PrivateMark, where: field(m, ^field) == ^old_id)) do
      exists? =
        Repo.exists?(
          from(m in PrivateMark,
            where: m.user_id == ^mark.user_id and field(m, ^field) == ^new.id
          )
        )

      if exists?,
        do: Repo.delete!(mark),
        else: mark |> Ecto.Changeset.change([{field, new.id}]) |> Repo.update!()
    end

    :ok
  end
end
