defmodule FinalTrack.Catalog.Artist do
  @moduledoc "An artist, shared by everyone. `key` is the normalised name."
  use FinalTrack.Schema

  schema "artists" do
    field :name, :string
    field :key, :string
    # The name as a hashtag (`FinalTrack.Catalog.hashtag/1`); nil if none.
    field :tag, :string

    has_many :albums, FinalTrack.Catalog.Album

    timestamps()
  end
end
