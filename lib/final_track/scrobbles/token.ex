defmodule FinalTrack.Scrobbles.Token do
  @moduledoc """
  A bearer token for a scrobbling client (one per device), bound to a user.

  Only a SHA-256 of the token is stored. The plaintext exists once, as
  `build/2` returns it, to be shown to the user and pasted into the client.
  """
  use FinalTrack.Schema
  import Ecto.Changeset

  @rand_size 32

  schema "scrobble_tokens" do
    field :token_hash, :binary, redact: true
    field :label, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, FinalTrack.Accounts.User

    timestamps()
  end

  @doc "A fresh token for `user_id`: `{plaintext, struct}`; only the struct's hash is stored."
  def build(user_id, attrs) do
    raw = :crypto.strong_rand_bytes(@rand_size)

    changeset =
      %__MODULE__{user_id: user_id, token_hash: hash(raw)}
      |> cast(attrs, [:label])
      |> update_change(:label, &String.trim/1)
      |> validate_length(:label, max: 80)

    {Base.url_encode64(raw, padding: false), changeset}
  end

  @doc "The stored hash of a token as a client presents it, or `:error` if it isn't one."
  def hash_presented(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} -> {:ok, hash(raw)}
      :error -> :error
    end
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)
end
