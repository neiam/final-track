defmodule FinalTrack.Scrobbles.PrivateMark do
  @moduledoc """
  An artist, album or track a user keeps to themselves: their plays of it
  are visible only to them (see `FinalTrack.Privacy`). Exactly one of the
  three is set.
  """
  use FinalTrack.Schema

  schema "private_marks" do
    belongs_to :user, FinalTrack.Accounts.User
    belongs_to :artist, FinalTrack.Catalog.Artist
    belongs_to :album, FinalTrack.Catalog.Album
    belongs_to :track, FinalTrack.Catalog.Track

    timestamps(updated_at: false)
  end
end
