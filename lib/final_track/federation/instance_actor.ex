defmodule FinalTrack.Federation.InstanceActor do
  @moduledoc """
  The server's own ActivityPub `Application` actor, at `/ap/actor`. It signs
  fetches made on nobody's behalf (looking up a remote actor to verify its
  signature, before any account is involved), since authorized-fetch
  servers such as mastodon.social refuse unsigned GETs. As angler's
  `Angler.Federation.InstanceActor`. Created, with its key pair, on first use.
  """
  use FinalTrack.Schema
  import Ecto.Query, only: [from: 2]

  alias FinalTrack.Repo

  schema "fediverse_instance_actor" do
    field :public_key_pem, :string
    field :private_key_pem, :string, redact: true

    timestamps()
  end

  @doc "The actor, created on first call."
  def ensure! do
    case oldest() do
      nil ->
        {public, private} = FinalTrack.Federation.Keys.generate()
        Repo.insert!(%__MODULE__{public_key_pem: public, private_key_pem: private})
        # Two first callers may race and both insert; the oldest row wins,
        # for everyone, from then on.
        oldest()

      actor ->
        actor
    end
  end

  defp oldest, do: Repo.one(from(a in __MODULE__, order_by: [a.inserted_at, a.id], limit: 1))
end
