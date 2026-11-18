defmodule FinalTrack.Federation.Account do
  @moduledoc """
  A user's fediverse account: `@username@host`, with the RSA key pair its
  requests are signed with. Exists once the user has set it up; posts only
  while `enabled` (and only while federation is on server-wide).
  """
  use FinalTrack.Schema
  import Ecto.Changeset

  @reserved ~w(admin administrator root system support help info api www mail abuse
               postmaster webmaster security noreply instance relay inbox outbox)

  schema "fediverse_accounts" do
    field :username, :string
    field :enabled, :boolean, default: false
    field :public_key_pem, :string
    field :private_key_pem, :string, redact: true

    belongs_to :user, FinalTrack.Accounts.User

    timestamps()
  end

  @doc """
  Username and on/off. A new account gets its key pair here. Usernames are
  what Mastodon accepts: lowercase letters, digits and underscores, 1-30.
  """
  def changeset(account, attrs), do: account |> validation_changeset(attrs) |> put_keys()

  @doc "The same checks without making keys: for a form as it's typed into."
  def validation_changeset(account, attrs) do
    account
    |> cast(attrs, [:username, :enabled])
    |> update_change(
      :username,
      &(&1 |> String.trim() |> String.trim_leading("@") |> String.downcase())
    )
    |> validate_required([:username])
    |> validate_length(:username, min: 1, max: 30)
    |> validate_format(:username, ~r/^[a-z0-9_]+$/,
      message: "only lowercase letters, numbers and underscores"
    )
    |> validate_exclusion(:username, @reserved, message: "is reserved")
    |> unsafe_validate_unique(:username, FinalTrack.Repo)
    |> unique_constraint(:username)
  end

  defp put_keys(%{data: %{private_key_pem: pem}} = changeset) when is_binary(pem), do: changeset

  defp put_keys(changeset) do
    if changeset.valid? do
      {public, private} = FinalTrack.Federation.Keys.generate()
      changeset |> put_change(:public_key_pem, public) |> put_change(:private_key_pem, private)
    else
      changeset
    end
  end
end
