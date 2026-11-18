defmodule FinalTrack.Privacy do
  @moduledoc """
  What each user keeps to themselves.

  A user can mark an artist, an album or a track private. Their plays of it
  then exist only for them: other people's charts, totals, "Listening now",
  "Latest plays" and album/artist pages leave those plays out. The rule is
  applied when reading, never when recording, so marking something hides
  past plays too, and unmarking brings them back.

  The rule, for a viewer: a play is visible if it is the viewer's own, or
  its owner has marked none of its artist, album and track private.
  `visible_to/2` applies it to any query over scrobbles bound `as: :scrobble`.
  """
  import Ecto.Query, warn: false

  alias FinalTrack.Accounts.User
  alias FinalTrack.Catalog.{Album, Artist, Track}
  alias FinalTrack.Repo
  alias FinalTrack.Scrobbles.PrivateMark

  @type target :: Artist.t() | Album.t() | Track.t()

  ## Marks

  @doc "Keeps `target` private for `user`. Marking twice is fine."
  def mark(%User{id: user_id}, target) do
    {field, id} = field(target)

    %PrivateMark{user_id: user_id}
    |> Map.put(field, id)
    |> Repo.insert(on_conflict: :nothing, conflict_target: {:unsafe_fragment, conflict(field)})
    |> case do
      # Anything already posted to the fediverse that this now covers is
      # withdrawn.
      {:ok, _} -> FinalTrack.Federation.retract_hidden(%User{id: user_id})
      error -> error
    end
  end

  @doc "Shares `target` again."
  def unmark(%User{id: user_id}, target) do
    {field, id} = field(target)

    Repo.delete_all(
      from(p in PrivateMark, where: p.user_id == ^user_id and field(p, ^field) == ^id)
    )

    :ok
  end

  @doc "Whether `user` keeps `target` private (that item itself, not through its artist or album)."
  def private?(%User{id: user_id}, target) do
    {field, id} = field(target)
    Repo.exists?(from(p in PrivateMark, where: p.user_id == ^user_id and field(p, ^field) == ^id))
  end

  @doc "The ids of the tracks among `track_ids` that `user` has marked private."
  def private_track_ids(%User{id: user_id}, track_ids) do
    from(p in PrivateMark,
      where: p.user_id == ^user_id and p.track_id in ^track_ids,
      select: p.track_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Everything `user` keeps private, newest first, with names loaded."
  def list_marks(%User{id: user_id}) do
    from(p in PrivateMark,
      where: p.user_id == ^user_id,
      order_by: [desc: p.inserted_at],
      preload: [:artist, album: :artist, track: :artist]
    )
    |> Repo.all()
  end

  @doc "Removes one of `user`'s marks by id."
  def delete_mark(%User{id: user_id}, mark_id) do
    with {:ok, mark_id} <- Ecto.UUID.cast(mark_id),
         {1, _} <-
           Repo.delete_all(
             from(p in PrivateMark, where: p.id == ^mark_id and p.user_id == ^user_id)
           ) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp field(%Artist{id: id}), do: {:artist_id, id}
  defp field(%Album{id: id}), do: {:album_id, id}
  defp field(%Track{id: id}), do: {:track_id, id}

  # Matches the partial unique indexes in the migration.
  defp conflict(field), do: "(user_id, #{field}) WHERE #{field} IS NOT NULL"

  ## The rule

  @doc """
  Restricts a query over scrobbles (bound `as: :scrobble`) to the plays
  `viewer` may see. With no viewer (a signed-out visitor), every play
  anyone has marked private is left out.
  """
  def visible_to(query, nil) do
    where(
      query,
      [scrobble: s],
      not exists(
        from(p in PrivateMark,
          where:
            p.user_id == parent_as(:scrobble).user_id and
              (p.artist_id == parent_as(:scrobble).artist_id or
                 p.album_id == parent_as(:scrobble).album_id or
                 p.track_id == parent_as(:scrobble).track_id),
          select: 1
        )
      )
    )
  end

  def visible_to(query, %User{id: viewer_id}) do
    where(
      query,
      [scrobble: s],
      s.user_id == ^viewer_id or
        not exists(
          from(p in PrivateMark,
            where:
              p.user_id == parent_as(:scrobble).user_id and
                (p.artist_id == parent_as(:scrobble).artist_id or
                   p.album_id == parent_as(:scrobble).album_id or
                   p.track_id == parent_as(:scrobble).track_id),
            select: 1
          )
        )
    )
  end

  @doc """
  The same rule for now-playing rows: a query over `NowPlaying` bound
  `as: :now_playing`, joined to its track `as: :np_track`.
  """
  def now_playing_visible_to(query, nil) do
    where(
      query,
      [now_playing: n],
      not exists(
        from(p in PrivateMark,
          where:
            p.user_id == parent_as(:now_playing).user_id and
              (p.artist_id == parent_as(:np_track).artist_id or
                 p.album_id == parent_as(:now_playing).album_id or
                 p.track_id == parent_as(:now_playing).track_id),
          select: 1
        )
      )
    )
  end

  def now_playing_visible_to(query, %User{id: viewer_id}) do
    where(
      query,
      [now_playing: n],
      n.user_id == ^viewer_id or
        not exists(
          from(p in PrivateMark,
            where:
              p.user_id == parent_as(:now_playing).user_id and
                (p.artist_id == parent_as(:np_track).artist_id or
                   p.album_id == parent_as(:now_playing).album_id or
                   p.track_id == parent_as(:now_playing).track_id),
            select: 1
          )
        )
    )
  end
end
