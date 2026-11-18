defmodule FinalTrack.Federation.RemoteActor do
  @moduledoc """
  What we know about an actor on another server: its inboxes and the key
  its requests are signed with. A cache, refreshed when a signature fails
  to verify (the key may have rotated).
  """
  use FinalTrack.Schema

  schema "fediverse_remote_actors" do
    field :ap_id, :string
    field :inbox, :string
    field :shared_inbox, :string
    field :public_key_id, :string
    field :public_key_pem, :string

    timestamps()
  end
end
