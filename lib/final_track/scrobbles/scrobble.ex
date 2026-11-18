defmodule FinalTrack.Scrobbles.Scrobble do
  @moduledoc """
  One confirmed play. `artist_id` and `album_id` are copied from the track
  and the client's album so charts can group without joins.
  """
  use FinalTrack.Schema

  schema "scrobbles" do
    field :played_at, :utc_datetime

    belongs_to :user, FinalTrack.Accounts.User
    belongs_to :track, FinalTrack.Catalog.Track
    belongs_to :artist, FinalTrack.Catalog.Artist
    belongs_to :album, FinalTrack.Catalog.Album

    timestamps(updated_at: false)
  end
end
