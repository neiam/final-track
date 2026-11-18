defmodule FinalTrack.Scrobbles do
  @moduledoc """
  Plays coming in from scrobbling clients, and the tokens they use.

  Speaks the Scropple HTTP backend's JSON (the same contract ircd's
  ScrobbleServ accepts), one object per play:

      {"artist": "…", "track": "…", "album": "…", "albumArtist": "…",
       "durationSec": 215, "timestamp": 1763494445}

  `artist` and `track` are required; the rest is optional. `timestamp` is
  when the play started, in Unix seconds; without one (or with one from the
  future) the play is stamped now.

  Recording is idempotent per (user, track, played_at): a client that
  retries a batch it already delivered adds nothing.

  Every recorded batch and now-playing change is broadcast on the
  `"scrobbles"` PubSub topic, so open pages update live.
  """
  import Ecto.Query, warn: false

  alias FinalTrack.Accounts.User
  alias FinalTrack.{Catalog, Covers, Privacy, Repo}
  alias FinalTrack.Scrobbles.{NowPlaying, Scrobble, Token}

  @topic "scrobbles"
  @limits %{"artist" => 256, "track" => 256, "album" => 256, "albumArtist" => 256}
  # How long a now-playing entry lasts when the client sent no duration.
  @default_now_playing_sec 10 * 60
  # A client clock may run a little fast; further ahead than this is wrong.
  @future_slack_sec 5 * 60
  # Before this, a timestamp is garbage, not a play (Last.fm's own floor).
  @earliest_unix 1_041_379_200

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(FinalTrack.PubSub, @topic)

  ## Tokens

  @doc """
  Mints a token for `user`. Returns `{:ok, plaintext, token}`: the plaintext
  is the only copy there will ever be.
  """
  def create_token(%User{id: user_id}, attrs \\ %{}) do
    {plaintext, changeset} = Token.build(user_id, attrs)

    with {:ok, token} <- Repo.insert(changeset), do: {:ok, plaintext, token}
  end

  @doc "A user's tokens, newest first."
  def list_tokens(%User{id: user_id}) do
    from(t in Token, where: t.user_id == ^user_id, order_by: [desc: t.inserted_at])
    |> Repo.all()
  end

  @doc "Deletes one of `user`'s tokens. Anyone else's, or a missing one, is `{:error, :not_found}`."
  def revoke_token(%User{id: user_id}, token_id) do
    with {:ok, token_id} <- Ecto.UUID.cast(token_id),
         {1, _} <-
           Repo.delete_all(from(t in Token, where: t.id == ^token_id and t.user_id == ^user_id)) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The user a presented bearer token belongs to, or `:error`. Marks the token
  used, at most once a minute so a busy client doesn't write on every call.
  """
  def verify_token(presented) when is_binary(presented) do
    with {:ok, hash} <- Token.hash_presented(presented),
         %Token{} = token <-
           Repo.one(from(t in Token, where: t.token_hash == ^hash, preload: :user)) do
      touch(token)
      {:ok, token.user}
    else
      _ -> :error
    end
  end

  defp touch(%Token{last_used_at: last} = token) do
    now = DateTime.utc_now(:second)

    if is_nil(last) or DateTime.diff(now, last) >= 60 do
      Repo.update_all(from(t in Token, where: t.id == ^token.id), set: [last_used_at: now])
    end
  end

  ## Validating what clients send

  @doc """
  Checks one play from a client and picks out its fields: `{:ok, play}` or
  `{:error, detail}`. Strings are trimmed, control characters dropped and
  lengths capped; unknown keys are ignored.
  """
  def validate_play(params) when is_map(params) do
    with {:ok, artist} <- text(params, "artist", true),
         {:ok, track} <- text(params, "track", true),
         {:ok, album} <- text(params, "album", false),
         {:ok, album_artist} <- text(params, "albumArtist", false) do
      {:ok,
       %{
         artist: artist,
         track: track,
         album: album,
         album_artist: album_artist,
         duration_sec: duration(params["durationSec"]),
         played_at: played_at(params["timestamp"])
       }}
    end
  end

  def validate_play(_), do: {:error, "body must be a JSON object"}

  defp text(params, key, required?) do
    case Map.get(params, key) do
      nil when required? ->
        {:error, "#{key}: is required"}

      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        cleaned = value |> String.replace(~r/[\x00-\x1f\x7f]/u, "") |> String.trim()

        cond do
          cleaned == "" and required? ->
            {:error, "#{key}: must not be blank"}

          cleaned == "" ->
            {:ok, nil}

          String.length(cleaned) > @limits[key] ->
            {:error, "#{key}: must be at most #{@limits[key]} characters"}

          true ->
            {:ok, cleaned}
        end

      _ ->
        {:error, "#{key}: must be a string"}
    end
  end

  defp duration(sec) when is_integer(sec) and sec > 0 and sec < 86_400, do: sec
  defp duration(_), do: nil

  defp played_at(ts) when is_integer(ts) do
    now = System.os_time(:second)

    if ts >= @earliest_unix and ts <= now + @future_slack_sec,
      do: DateTime.from_unix!(min(ts, now)),
      else: DateTime.from_unix!(now)
  end

  defp played_at(_), do: DateTime.utc_now(:second)

  ## Recording

  @doc """
  Records validated plays (see `validate_play/1`) for `user`. Returns how
  many were new; repeats of plays already recorded are skipped.
  """
  def record_plays(%User{} = user, plays) when is_list(plays) do
    {new_ids, albums} =
      Enum.reduce(plays, {[], %{}}, fn play, {new_ids, albums} ->
        {inserted, album} = record_play(user, play)
        albums = if album, do: Map.put(albums, album.id, album), else: albums
        {inserted ++ new_ids, albums}
      end)

    new = length(new_ids)
    if new > 0, do: broadcast({:scrobbled, user.id, new})
    # Covers first: a post waits a moment so a freshly fetched one can join it.
    Enum.each(Map.values(albums), &Covers.maybe_fetch/1)
    FinalTrack.Federation.publish_plays(user, new_ids)
    new
  end

  defp record_play(user, play) do
    %{track: track, artist: artist, album: album} = catalog(play)

    {_count, inserted} =
      Repo.insert_all(
        Scrobble,
        [
          %{
            id: FinalTrack.UUIDv7.generate(),
            user_id: user.id,
            track_id: track.id,
            artist_id: artist.id,
            album_id: album && album.id,
            played_at: DateTime.truncate(play.played_at, :second),
            inserted_at: DateTime.utc_now(:second)
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:user_id, :track_id, :played_at],
        returning: [:id]
      )

    {Enum.map(inserted, & &1.id), album}
  end

  # The catalog entries a play names: the track under its artist, and the
  # album under its album artist (the track artist when none was sent).
  defp catalog(play) do
    artist = Catalog.ensure_artist!(play.artist)
    track = Catalog.ensure_track!(artist, play.track, play.duration_sec)

    album =
      if play.album do
        album_artist =
          if play.album_artist && Catalog.normalize(play.album_artist) != artist.key,
            do: Catalog.ensure_artist!(play.album_artist),
            else: artist

        Catalog.ensure_album!(album_artist, play.album)
      end

    %{artist: artist, track: track, album: album}
  end

  ## Now playing

  @doc "Marks what `user` is listening to now (a validated play)."
  def set_now_playing(%User{} = user, play) do
    %{track: track, album: album} = catalog(play)
    now = DateTime.utc_now(:second)
    expires_at = DateTime.add(now, play.duration_sec || @default_now_playing_sec)

    Repo.insert!(
      %NowPlaying{
        user_id: user.id,
        track_id: track.id,
        album_id: album && album.id,
        started_at: now,
        expires_at: expires_at
      },
      on_conflict: {:replace, [:track_id, :album_id, :started_at, :expires_at]},
      conflict_target: :user_id
    )

    broadcast({:now_playing, user.id})
    if album, do: Covers.maybe_fetch(album)
    :ok
  end

  @doc """
  Who is listening to what right now, most recently started first, as
  `viewer` may see it (others' private listening is left out).
  """
  def now_playing(viewer) when is_nil(viewer) or is_struct(viewer, User) do
    now = DateTime.utc_now(:second)

    from(n in NowPlaying,
      as: :now_playing,
      join: t in assoc(n, :track),
      as: :np_track,
      where: n.expires_at > ^now,
      order_by: [desc: n.started_at],
      preload: [:user, track: :artist, album: :artist]
    )
    |> Privacy.now_playing_visible_to(viewer)
    |> Repo.all()
  end

  ## Reading

  @doc """
  The latest plays, newest first, for an audience (see
  `FinalTrack.Charts.audience/2`): everyone's or one person's, as the
  viewer may see them.
  """
  def recent(%{viewer: viewer, only: only}, limit \\ 20) do
    from(s in Scrobble,
      as: :scrobble,
      order_by: [desc: s.played_at, desc: s.id],
      limit: ^limit,
      preload: [:user, track: :artist, album: :artist]
    )
    |> Privacy.visible_to(viewer)
    |> then(fn q -> if only, do: where(q, [scrobble: s], s.user_id == ^only.id), else: q end)
    |> Repo.all()
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(FinalTrack.PubSub, @topic, message)
end
