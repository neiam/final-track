defmodule FinalTrack.Catalog.Track do
  @moduledoc "A track, under its artist. `key` is the normalised title."
  use FinalTrack.Schema

  schema "tracks" do
    field :title, :string
    field :key, :string
    field :duration_sec, :integer

    belongs_to :artist, FinalTrack.Catalog.Artist

    timestamps()
  end
end
