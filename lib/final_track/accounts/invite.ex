defmodule FinalTrack.Accounts.Invite do
  @moduledoc """
  A single-use registration invite. When `FinalTrack.Accounts.registration_open?/0`
  returns false, `/users/register` only accepts visitors carrying a
  valid invite token in the URL.

  An invite may be addressed to an `email`. Then the link is for that
  person only: it shows the address fixed, asks for a password,
  and creates the account already confirmed (holding the link stands in for
  the confirmation email). An unaddressed invite proves nothing about an
  address, so it confirms nothing.

  Only a SHA-256 of the token is stored (`token_hash`). The raw token is in
  the link alone, and on the struct (the virtual `token`) only as it comes
  back from creating or rotating, which is the one time to show the link.
  """
  use FinalTrack.Schema
  import Ecto.Changeset

  alias FinalTrack.Accounts.User

  schema "invites" do
    field :token, :string, virtual: true, redact: true
    field :token_hash, :binary, redact: true
    field :note, :string
    field :email, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :created_by, User
    belongs_to :consumed_by, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [:note, :email, :created_by_id, :expires_at])
    |> update_change(:email, &String.trim/1)
    |> put_new_token()
    |> validate_length(:note, max: 200)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Stamps the invite as consumed by the given user. Idempotent: a second
  call returns the same record without re-stamping.
  """
  def consume_changeset(invite, %User{id: user_id}) do
    if invite.consumed_at do
      change(invite)
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      change(invite, consumed_at: now, consumed_by_id: user_id)
    end
  end

  @doc "A new token, so every earlier link to this invite stops working."
  def rotate_token_changeset(invite) do
    invite |> change() |> put_new_token()
  end

  @doc "A new link token: `{raw, hash}`. Only the hash is stored."
  def build_token do
    raw = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    {raw, hash_token(raw)}
  end

  @doc "The stored form of a link token."
  def hash_token(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw)

  @spec active?(%__MODULE__{}) :: boolean()
  def active?(%__MODULE__{consumed_at: nil, expires_at: nil}), do: true

  def active?(%__MODULE__{consumed_at: nil, expires_at: %DateTime{} = exp}) do
    DateTime.compare(exp, DateTime.utc_now()) == :gt
  end

  def active?(_), do: false

  @doc "One line on what an invite's link does, for the command-line tasks."
  def describe(%__MODULE__{email: nil}),
    do:
      "Single-use registration link (not emailed; hand it over). Anyone holding it can register."

  def describe(%__MODULE__{email: email}),
    do:
      "Single-use registration link for #{email} (not emailed; hand it over). " <>
        "They choose a password and are signed in, their email counted as confirmed; " <>
        "if it already has an account, the link sends them to log in."

  defp put_new_token(changeset) do
    {raw, hash} = build_token()
    changeset |> put_change(:token, raw) |> put_change(:token_hash, hash)
  end
end
