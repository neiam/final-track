defmodule FinalTrack.Scrobbles.NowPlaying do
  @moduledoc """
  What a user is listening to right now: one row per user, replaced on each
  now-playing update and ignored once past `expires_at` (the track's length,
  or a default when the client didn't send one).
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type FinalTrack.UUIDv7

  schema "now_playing" do
    belongs_to :user, FinalTrack.Accounts.User, primary_key: true
    belongs_to :track, FinalTrack.Catalog.Track
    belongs_to :album, FinalTrack.Catalog.Album
    field :started_at, :utc_datetime
    field :expires_at, :utc_datetime
  end
end
