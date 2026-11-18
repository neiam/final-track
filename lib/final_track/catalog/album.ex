defmodule FinalTrack.Catalog.Album do
  @moduledoc """
  An album, under its album artist. Carries the cover: `cover_key` names the
  file in `FinalTrack.Covers.Store`, `cover_source` says where it came from
  (`"upload"` or `"coverartarchive"`).
  """
  use FinalTrack.Schema

  schema "albums" do
    field :title, :string
    field :key, :string
    field :cover_key, :string
    field :cover_source, :string
    field :mbid, :string
    field :cover_checked_at, :utc_datetime

    belongs_to :artist, FinalTrack.Catalog.Artist

    timestamps()
  end
end
