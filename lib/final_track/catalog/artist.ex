defmodule FinalTrack.Catalog.Artist do
  @moduledoc "An artist, shared by everyone. `key` is the normalised name."
  use FinalTrack.Schema

  schema "artists" do
    field :name, :string
    field :key, :string

    has_many :albums, FinalTrack.Catalog.Album

    timestamps()
  end
end
