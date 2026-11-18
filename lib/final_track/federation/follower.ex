defmodule FinalTrack.Federation.Follower do
  @moduledoc "A remote actor following one of our accounts, with where to deliver to it."
  use FinalTrack.Schema

  schema "fediverse_followers" do
    field :actor_id, :string
    field :inbox, :string
    field :shared_inbox, :string

    belongs_to :account, FinalTrack.Federation.Account

    timestamps()
  end
end
