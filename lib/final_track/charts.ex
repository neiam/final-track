defmodule FinalTrack.Charts do
  @moduledoc """
  Popularity: the most-played artists, albums and tracks in a
  `FinalTrack.Charts.Period`, plays over time within it, and all-time
  numbers for one album or artist.

  Every query is for an audience, `%{viewer: user, only: user | nil}`:
  `viewer` is who is looking (`nil` for a signed-out visitor), and the plays they can't see (someone else's
  private ones, see `FinalTrack.Privacy`) are left out; `only` narrows to
  one person's plays, `nil` meaning everyone's. `audience/2` builds one.

  Period queries also take the viewer's IANA time zone. Plays are stored in
  UTC; Postgres shifts them into that zone (its own zone database, so the
  app needs none) and compares them to the period's local bounds, so a day
  chart is midnight to midnight where the viewer is.
  """
  import Ecto.Query, warn: false

  alias FinalTrack.Accounts.User
  alias FinalTrack.Catalog.{Album, Artist, Track}
  alias FinalTrack.Charts.Period
  alias FinalTrack.{Privacy, Repo}
  alias FinalTrack.Scrobbles.Scrobble

  @default_zone "Etc/UTC"

  @type audience :: %{viewer: User.t(), only: User.t() | nil}

  @doc "Everyone's plays as `viewer` may see them, or (with `only`) one person's."
  def audience(viewer, only \\ nil) when is_nil(viewer) or is_struct(viewer, User),
    do: %{viewer: viewer, only: only}

  @doc """
  `zone` if Postgres knows it, else UTC. Zones come from the browser, so
  they are checked before going anywhere near a query.
  """
  def time_zone(zone) when is_binary(zone) and byte_size(zone) <= 64 do
    case Repo.query!("SELECT 1 FROM pg_timezone_names WHERE name = $1", [zone]) do
      %{num_rows: 0} -> @default_zone
      _ -> zone
    end
  end

  def time_zone(_), do: @default_zone

  @doc "Today's date in `zone`."
  def today(zone) do
    %{rows: [[date]]} = Repo.query!("SELECT (now() AT TIME ZONE $1)::date", [zone])
    date
  end

  ## A period

  @doc "Top artists: `[%{artist: %Artist{}, plays: n}]`, most played first."
  def top_artists(%Period{} = period, zone, audience, limit \\ 10) do
    period
    |> in_period(zone, audience)
    |> join(:inner, [scrobble: s], a in Artist, on: a.id == s.artist_id, as: :item)
    |> top(limit)
    |> select([scrobble: s, item: a], %{artist: a, plays: count(s.id)})
    |> Repo.all()
  end

  @doc "Top albums: `[%{album: %Album{artist: _}, plays: n}]`, most played first."
  def top_albums(%Period{} = period, zone, audience, limit \\ 10) do
    period
    |> in_period(zone, audience)
    |> join(:inner, [scrobble: s], al in Album, on: al.id == s.album_id, as: :item)
    |> top(limit)
    |> select([scrobble: s, item: al], %{album: al, plays: count(s.id)})
    |> Repo.all()
    |> preload_in(:album, :artist)
  end

  @doc "Top tracks: `[%{track: %Track{artist: _}, plays: n}]`, most played first."
  def top_tracks(%Period{} = period, zone, audience, limit \\ 10) do
    period
    |> in_period(zone, audience)
    |> join(:inner, [scrobble: s], t in Track, on: t.id == s.track_id, as: :item)
    |> top(limit)
    |> select([scrobble: s, item: t], %{track: t, plays: count(s.id)})
    |> Repo.all()
    |> preload_in(:track, :artist)
  end

  @doc "How many plays the period holds."
  def total_plays(%Period{} = period, zone, audience) do
    period |> in_period(zone, audience) |> select([scrobble: s], count(s.id)) |> Repo.one()
  end

  @doc """
  Plays over the period, one entry per bar of `Period.buckets/1` (empty
  bars included): `[%{at: naive_start, label: "Mon", plays: n}]`.
  """
  def timeline(%Period{} = period, zone, audience) do
    {step, keys} = Period.buckets(period)

    counts =
      period
      |> in_period(zone, audience)
      # Grouped by the selected alias: repeating the expression would bind
      # fresh parameters, and Postgres can't tell the two are the same.
      |> select([scrobble: s], %{
        at:
          selected_as(
            fragment(
              "date_trunc(?, (? AT TIME ZONE 'UTC') AT TIME ZONE ?)",
              ^step,
              s.played_at,
              ^zone
            ),
            :bucket
          ),
        plays: count(s.id)
      })
      |> group_by(selected_as(:bucket))
      |> Repo.all()
      |> Map.new(fn %{at: at, plays: n} -> {NaiveDateTime.truncate(at, :second), n} end)

    for at <- keys,
        do: %{at: at, label: Period.bucket_label(period, at), plays: Map.get(counts, at, 0)}
  end

  ## One album, one artist (all time)

  @doc "`%{plays: n, listeners: n, first: dt | nil, last: dt | nil}` for an album or artist."
  def summary(%Album{id: id}, audience),
    do: summarize(where(plays(audience), [scrobble: s], s.album_id == ^id))

  def summary(%Artist{id: id}, audience),
    do: summarize(where(plays(audience), [scrobble: s], s.artist_id == ^id))

  defp summarize(query) do
    query
    |> select([scrobble: s], %{
      plays: count(s.id),
      listeners: count(s.user_id, :distinct),
      first: min(s.played_at),
      last: max(s.played_at)
    })
    |> Repo.one()
  end

  @doc "The album's tracks as played on it, most played first."
  def album_tracks(%Album{id: id}, audience) do
    audience
    |> plays()
    |> where([scrobble: s], s.album_id == ^id)
    |> join(:inner, [scrobble: s], t in Track, on: t.id == s.track_id, as: :item)
    |> top(nil)
    |> select([scrobble: s, item: t], %{track: t, plays: count(s.id)})
    |> Repo.all()
  end

  @doc "An artist's most played tracks."
  def artist_tracks(%Artist{id: id}, audience, limit \\ 10) do
    audience
    |> plays()
    |> where([scrobble: s], s.artist_id == ^id)
    |> join(:inner, [scrobble: s], t in Track, on: t.id == s.track_id, as: :item)
    |> top(limit)
    |> select([scrobble: s, item: t], %{track: t, plays: count(s.id)})
    |> Repo.all()
  end

  @doc """
  The artist's albums (as album artist) with the plays `audience` can see,
  most played first. An album nobody visible has played is still listed,
  with 0, as long as it has a cover or some visible play; otherwise it's
  left out, so a private listen doesn't show up as an album name.
  """
  def artist_albums(%Artist{id: id}, audience) do
    visible = audience |> plays() |> select([scrobble: s], %{album_id: s.album_id, id: s.id})

    from(al in Album,
      left_join: s in subquery(visible),
      on: s.album_id == al.id,
      where: al.artist_id == ^id,
      group_by: al.id,
      having: count(s.id) > 0 or not is_nil(al.cover_key),
      order_by: [desc: count(s.id), asc: al.key],
      select: %{album: al, plays: count(s.id)}
    )
    |> Repo.all()
  end

  ## The library: every artist or album, with its numbers

  @library_sorts ~w(plays name recent)a

  def library_sorts, do: @library_sorts

  @doc "Parses a sort from a URL param, defaulting to `:plays`."
  def parse_sort(sort) when is_binary(sort),
    do: Enum.find(@library_sorts, :plays, &(Atom.to_string(&1) == sort))

  def parse_sort(_), do: :plays

  @doc """
  One page of artists with the plays `audience` can see:
  `[%{artist:, plays:, listeners:, tracks:, albums:, first:, last:}]`.
  Only artists with at least one such play are listed.

  Options: `:sort` (`:plays`, `:name` or `:recent`), `:search` (part of
  the name, any case), `:limit` (default 50) and `:offset`.
  """
  def library_artists(audience, opts \\ []) do
    audience
    |> plays()
    |> join(:inner, [scrobble: s], a in Artist, on: a.id == s.artist_id, as: :item)
    |> search_artists(opts[:search])
    |> group_by([item: a], a.id)
    |> library_order(opts[:sort])
    |> page(opts)
    |> select([scrobble: s, item: a], %{
      artist: a,
      plays: count(s.id),
      listeners: count(s.user_id, :distinct),
      tracks: count(s.track_id, :distinct),
      albums: count(s.album_id, :distinct),
      first: min(s.played_at),
      last: max(s.played_at)
    })
    |> Repo.all()
  end

  @doc """
  One page of albums with the plays `audience` can see:
  `[%{album: (artist loaded), plays:, listeners:, tracks:, first:, last:}]`.
  Search matches the title or the album artist. Options as
  `library_artists/2`.
  """
  def library_albums(audience, opts \\ []) do
    audience
    |> plays()
    |> join(:inner, [scrobble: s], al in Album, on: al.id == s.album_id, as: :item)
    |> join(:inner, [item: al], ar in Artist, on: ar.id == al.artist_id, as: :album_artist)
    |> search_albums(opts[:search])
    |> group_by([item: al, album_artist: ar], [al.id, ar.id])
    |> library_order(opts[:sort])
    |> page(opts)
    |> select([scrobble: s, item: al, album_artist: ar], %{
      album: %{al | artist: ar},
      plays: count(s.id),
      listeners: count(s.user_id, :distinct),
      tracks: count(s.track_id, :distinct),
      first: min(s.played_at),
      last: max(s.played_at)
    })
    |> Repo.all()
  end

  @doc """
  `%{count: how many artists or albums match, max_plays: the most any of
  them has}`, for the library's header and its bars.
  """
  def library_stats(kind, audience, opts \\ []) when kind in [:artists, :albums] do
    per_item =
      case kind do
        :artists ->
          audience
          |> plays()
          |> join(:inner, [scrobble: s], a in Artist, on: a.id == s.artist_id, as: :item)
          |> search_artists(opts[:search])

        :albums ->
          audience
          |> plays()
          |> join(:inner, [scrobble: s], al in Album, on: al.id == s.album_id, as: :item)
          |> join(:inner, [item: al], ar in Artist, on: ar.id == al.artist_id, as: :album_artist)
          |> search_albums(opts[:search])
      end
      |> group_by([item: i], i.id)
      |> select([scrobble: s], %{plays: count(s.id)})

    from(x in subquery(per_item), select: %{count: count(), max_plays: coalesce(max(x.plays), 0)})
    |> Repo.one()
  end

  # Case-insensitive substring matches, with LIKE's wildcards taken literally.
  defp search_artists(query, term) do
    case like_pattern(term) do
      nil -> query
      pattern -> where(query, [item: a], ilike(a.name, ^pattern))
    end
  end

  defp search_albums(query, term) do
    case like_pattern(term) do
      nil ->
        query

      pattern ->
        where(
          query,
          [item: al, album_artist: ar],
          ilike(al.title, ^pattern) or ilike(ar.name, ^pattern)
        )
    end
  end

  defp like_pattern(term) when is_binary(term) do
    case String.trim(term) do
      "" -> nil
      term -> "%" <> String.replace(term, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
    end
  end

  defp like_pattern(_), do: nil

  defp library_order(query, :name), do: order_by(query, [item: i], asc: i.key)

  defp library_order(query, :recent),
    do: order_by(query, [scrobble: s, item: i], desc: max(s.played_at), asc: i.key)

  defp library_order(query, _plays),
    do: order_by(query, [scrobble: s, item: i], desc: count(s.id), asc: i.key)

  defp page(query, opts) do
    query
    |> limit(^Keyword.get(opts, :limit, 50))
    |> offset(^Keyword.get(opts, :offset, 0))
  end

  ## Building blocks

  # The scrobbles `audience` may see, bound as :scrobble.
  defp plays(%{viewer: viewer} = audience) do
    from(s in Scrobble, as: :scrobble)
    |> Privacy.visible_to(viewer)
    |> only(audience)
  end

  defp only(query, %{only: %User{id: id}}), do: where(query, [scrobble: s], s.user_id == ^id)
  defp only(query, _), do: query

  # ...whose local time falls in the period.
  defp in_period(%Period{} = period, zone, audience) do
    {from, to} = Period.bounds(period)

    audience
    |> plays()
    |> where(
      [scrobble: s],
      fragment("(? AT TIME ZONE 'UTC') AT TIME ZONE ?", s.played_at, ^zone) >= ^from and
        fragment("(? AT TIME ZONE 'UTC') AT TIME ZONE ?", s.played_at, ^zone) < ^to
    )
  end

  # Group by the joined :item, most plays first, ties by name.
  defp top(query, limit) do
    query =
      query
      |> group_by([item: i], i.id)
      |> order_by([scrobble: s, item: i], desc: count(s.id), asc: i.key)

    if limit, do: limit(query, ^limit), else: query
  end

  defp preload_in(rows, key, assoc) do
    loaded = rows |> Enum.map(&Map.fetch!(&1, key)) |> Repo.preload(assoc)
    Enum.zip_with(rows, loaded, &Map.put(&1, key, &2))
  end
end
